#!/usr/bin/env python3
"""Generate a synthetic provider roster CSV for testing roster file validation.

Uses only the standard library. All generated identifiers are deliberately
non-real: SSNs use the 9xx area (never issued), phones use the 555-01xx
fictional range, and emails use example.com. NPIs are random but carry a
valid Luhn check digit so they pass format validation.

Provider Unique ID is left blank: ingestion requires a supplied Unique ID to
identify an existing Provider, so generated rows describe new Providers and are
matched by NPI. To exercise the update path, pass --existing-ids with real
Provider keys from the org; those rows become updates of existing Providers.

Examples:
    python3 scripts/generate_roster_csv.py --rows 100 -o roster.csv
    python3 scripts/generate_roster_csv.py --rows 500 --error-rate 0.1 --seed 42 > roster.csv
    python3 scripts/generate_roster_csv.py --rows 500 --existing-ids providers.csv -o roster.csv

The --existing-ids file has one Provider per line: the InnovAge Unique ID,
optionally followed by a comma and the Provider's NPI. Export it with:
    sf data query -o innovage -r csv \\
        -q "SELECT InnovAge_Unique_ID__c, NPI__c FROM Account WHERE RecordType.DeveloperName = 'Provider' LIMIT 100"
(a header line, if present, is skipped).
"""

import argparse
import csv
import random
import re
import sys
from datetime import date, timedelta

HEADERS = [
    "Provider Effective Date",
    "Roster Line Type",
    "Provider Unique ID",
    "Salutation",
    "First Name",
    "Middle Name",
    "Last Name",
    "Suffix (MD, DO, NP, RN etc)",
    "Date of Birth",
    "Gender Identification",
    "Pronouns",
    "Social Security Number",
    "Provider Phone",
    "Provider Fax",
    "Provider Email",
    "Primary Provider Language",
    "Secondary Provider Language(s)",
    "Provider Mailing Address Line 1",
    "Provider Mailing Address Line 2",
    "Provider Mailing City",
    "Provider Mailing State",
    "Provider Mailing Zip",
    "Provider Billing Address Line 1",
    "Provider Billing Address Line 2",
    "Provider Billing City",
    "Provider Billing State",
    "Provider Billing Zip",
    "Primary Provider Specialty",
    "Additional Provider Specialty",
    "CAQH ID",
    "Initial Credentialing Date",
    "Last Credentialing Date",
    "Individual NPI",
    "Provider Attests to Providing Gender Affirming Care?",
    "Medicare ID",
    "Medicaid ID State",
    "Medicaid ID",
]

DATE_FORMAT = "%m/%d/%Y"

FIRST_NAMES = [
    "Jordan", "Avery", "Morgan", "Taylor", "Casey", "Riley", "Jamie", "Quinn",
    "Alex", "Sam", "Maria", "James", "Priya", "Wei", "Fatima", "Carlos",
    "Aisha", "David", "Elena", "Kenji", "Olivia", "Noah", "Sofia", "Liam",
]
LAST_NAMES = [
    "Mitchell", "Nguyen", "Garcia", "Patel", "Johnson", "Kim", "Okafor",
    "Martinez", "Chen", "Williams", "Brown", "Rossi", "Haddad", "Silva",
    "Andersen", "Kowalski", "Lopez", "Tanaka", "Murphy", "Singh",
]
SUFFIXES = ["MD", "DO", "NP", "RN", "PA-C", "LCSW", "PhD", "DPM"]
GENDERS = [
    ("Female", "She/Her"),
    ("Male", "He/Him"),
    ("Non-binary", "They/Them"),
    ("Prefer not to say", ""),
]
LANGUAGES = [
    "English", "Spanish", "French", "Vietnamese", "Mandarin", "Russian",
    "Arabic", "Korean", "Tagalog", "Amharic",
]
SPECIALTIES = [
    "Internal Medicine", "Family Medicine", "Geriatric Medicine", "Cardiology",
    "Psychiatry", "Podiatry", "Physical Therapy", "Occupational Therapy",
    "Social Work", "Nursing", "Endocrinology", "Neurology",
]
STREETS = [
    "Elm Street", "Colfax Avenue", "Broadway", "Main Street", "Pine Street",
    "Federal Boulevard", "Cherry Creek Drive", "Wadsworth Boulevard",
]
# (city, state, zip prefix)
CITIES = [
    ("Denver", "CO", "802"),
    ("Aurora", "CO", "800"),
    ("Colorado Springs", "CO", "809"),
    ("Pueblo", "CO", "810"),
    ("Albuquerque", "NM", "871"),
    ("Sacramento", "CA", "958"),
    ("Richmond", "VA", "232"),
    ("Allentown", "PA", "181"),
]
ROSTER_LINE_TYPES = ["Add", "Change", "Term"]

# InnovAge Unique ID of a Provider: P + 9-digit auto-number + last 3 characters of the record Id
# (see InnovAgeUniqueId.cls).
PROVIDER_UNIQUE_ID = re.compile(r"^P\d{9}[A-Za-z0-9]{3}$")


def random_date(start: date, end: date) -> date:
    return start + timedelta(days=random.randint(0, (end - start).days))


def fmt(d: date) -> str:
    return d.strftime(DATE_FORMAT)


def npi_check_digit(first_nine: str) -> int:
    """Luhn check digit for an NPI, including the 80840 prefix constant (24)."""
    total = 24
    for i, ch in enumerate(first_nine):
        n = int(ch)
        if i % 2 == 0:  # double every other digit starting from the leftmost
            n *= 2
            if n > 9:
                n -= 9
        total += n
    return (10 - total % 10) % 10


def generate_npi() -> str:
    first_nine = random.choice("12") + "".join(random.choices("0123456789", k=8))
    return first_nine + str(npi_check_digit(first_nine))


def generate_ssn() -> str:
    # Area numbers 900-999 are never issued as SSNs.
    return f"{random.randint(900, 999)}-{random.randint(10, 99):02d}-{random.randint(1, 9999):04d}"


def generate_phone() -> str:
    return f"({random.randint(201, 989)}) 555-01{random.randint(0, 99):02d}"


def generate_zip(prefix: str, plus_four: bool) -> str:
    zip5 = f"{prefix}{random.randint(1, 99):02d}"
    return f"{zip5}-{random.randint(1, 9999):04d}" if plus_four else zip5


def generate_address() -> dict:
    city, state, zip_prefix = random.choice(CITIES)
    line2 = random.choice(["", "", f"Suite {random.randint(100, 999)}", f"Unit {random.randint(1, 50)}"])
    return {
        "line1": f"{random.randint(100, 9999)} {random.choice(STREETS)}",
        "line2": line2,
        "city": city,
        "state": state,
        "zip": generate_zip(zip_prefix, plus_four=random.random() < 0.3),
    }


def generate_row(index: int, existing: tuple = None) -> dict:
    """A valid row for a new Provider, or an update of an existing one ((unique_id, npi) in existing)."""
    today = date.today()
    first = random.choice(FIRST_NAMES)
    last = random.choice(LAST_NAMES)
    gender, pronouns = random.choice(GENDERS)
    primary_language = random.choice(LANGUAGES[:3]) if random.random() < 0.9 else random.choice(LANGUAGES)
    secondary = random.sample([l for l in LANGUAGES if l != primary_language], k=random.randint(0, 2))
    primary_specialty = random.choice(SPECIALTIES)
    additional_specialty = random.choice(
        [""] + [s for s in SPECIALTIES if s != primary_specialty]
    )

    mailing = generate_address()
    billing = mailing if random.random() < 0.5 else generate_address()

    dob = random_date(date(1950, 1, 1), date(1995, 12, 31))
    initial_cred = random_date(date(2010, 1, 1), today - timedelta(days=365))
    last_cred = random_date(initial_cred, today)
    medicaid_state = mailing["state"]

    return {
        "Provider Effective Date": fmt(random_date(today - timedelta(days=90), today + timedelta(days=90))),
        "Roster Line Type": random.choices(ROSTER_LINE_TYPES, weights=[70, 20, 10])[0],
        "Provider Unique ID": existing[0] if existing else "",
        "Salutation": random.choice(["Dr.", "Dr.", "Mr.", "Ms.", "Mx.", ""]),
        "First Name": first,
        "Middle Name": random.choice(FIRST_NAMES) if random.random() < 0.6 else "",
        "Last Name": last,
        "Suffix (MD, DO, NP, RN etc)": random.choice(SUFFIXES),
        "Date of Birth": fmt(dob),
        "Gender Identification": gender,
        "Pronouns": pronouns,
        "Social Security Number": generate_ssn(),
        "Provider Phone": generate_phone(),
        "Provider Fax": generate_phone() if random.random() < 0.7 else "",
        "Provider Email": f"{first.lower()}.{last.lower()}{index}@example.com",
        "Primary Provider Language": primary_language,
        "Secondary Provider Language(s)": ", ".join(secondary),
        "Provider Mailing Address Line 1": mailing["line1"],
        "Provider Mailing Address Line 2": mailing["line2"],
        "Provider Mailing City": mailing["city"],
        "Provider Mailing State": mailing["state"],
        "Provider Mailing Zip": mailing["zip"],
        "Provider Billing Address Line 1": billing["line1"],
        "Provider Billing Address Line 2": billing["line2"],
        "Provider Billing City": billing["city"],
        "Provider Billing State": billing["state"],
        "Provider Billing Zip": billing["zip"],
        "Primary Provider Specialty": primary_specialty,
        "Additional Provider Specialty": additional_specialty,
        "CAQH ID": f"{random.randint(10000000, 19999999)}",
        "Initial Credentialing Date": fmt(initial_cred),
        "Last Credentialing Date": fmt(last_cred),
        # An existing Provider keeps its own NPI (a different one would be a key mismatch).
        "Individual NPI": existing[1] if existing else generate_npi(),
        "Provider Attests to Providing Gender Affirming Care?": random.choice(["Yes", "No"]),
        "Medicare ID": f"{medicaid_state}{random.randint(1000000, 9999999)}",
        "Medicaid ID State": medicaid_state,
        "Medicaid ID": f"{random.choice('ABCDEFGHJKLMNPRSTUVWXYZ')}{random.randint(100000, 999999)}",
    }


# Each error mutates a valid row in place and returns a short description.
def _bad_npi(row):
    npi = row["Individual NPI"] or generate_npi()
    row["Individual NPI"] = npi[:9] + str((int(npi[9]) + 1) % 10)
    return "NPI with invalid check digit"


def _short_npi(row):
    row["Individual NPI"] = (row["Individual NPI"] or generate_npi())[:8]
    return "NPI with wrong length"


def _bad_dob(row):
    row["Date of Birth"] = random.choice(["13/45/1980", "1980-04-17", "not a date"])
    return "malformed Date of Birth"


def _future_dob(row):
    row["Date of Birth"] = fmt(date.today() + timedelta(days=random.randint(1, 3650)))
    return "Date of Birth in the future"


def _bad_unique_id(row):
    row["Provider Unique ID"] = random.choice(["PRV-000123", "P12345", "PG000000001abc"])
    return "malformed Provider Unique ID"


def _missing_required(row):
    field = random.choice(["First Name", "Last Name", "Individual NPI", "Provider Effective Date", "Roster Line Type"])
    row[field] = ""
    return f"missing {field}"


def _bad_ssn(row):
    row["Social Security Number"] = random.choice(["123-45-678", "12345678A", "000-00-0000"])
    return "malformed SSN"


def _bad_state(row):
    row["Provider Mailing State"] = random.choice(["Colorado", "XX", "C0"])
    return "invalid Mailing State"


def _bad_zip(row):
    row["Provider Mailing Zip"] = random.choice(["8020", "802021", "ABCDE"])
    return "invalid Mailing Zip"


def _bad_email(row):
    row["Provider Email"] = row["Provider Email"].replace("@", "")
    return "invalid email"


def _bad_line_type(row):
    row["Roster Line Type"] = random.choice(["Insert", "Delete", "add-provider"])
    return "invalid Roster Line Type"


def _cred_order(row):
    row["Initial Credentialing Date"], row["Last Credentialing Date"] = (
        fmt(date.today() - timedelta(days=30)),
        fmt(date.today() - timedelta(days=400)),
    )
    return "Last Credentialing Date before Initial Credentialing Date"


ERROR_INJECTORS = [
    _bad_npi, _short_npi, _bad_dob, _future_dob, _missing_required, _bad_ssn,
    _bad_state, _bad_zip, _bad_email, _bad_line_type, _cred_order, _bad_unique_id,
]


def read_existing_ids(path: str) -> list:
    """(unique_id, npi) pairs from --existing-ids; npi is "" when not given."""
    existing = []
    with open(path, newline="", encoding="utf-8") as f:
        for line_no, fields in enumerate(csv.reader(f), start=1):
            fields = [value.strip() for value in fields]
            if not fields or not fields[0]:
                continue
            unique_id = fields[0]
            if not PROVIDER_UNIQUE_ID.match(unique_id):
                if line_no == 1:
                    continue  # header line
                sys.exit(f"{path} line {line_no}: {unique_id!r} is not a Provider Unique ID (P + 9 digits + 3 characters)")
            existing.append((unique_id, fields[1] if len(fields) > 1 else ""))
    return existing


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-n", "--rows", type=int, default=10, help="number of data rows (default: 10)")
    parser.add_argument("-o", "--output", help="output file path (default: stdout)")
    parser.add_argument("--seed", type=int, help="random seed for reproducible output")
    parser.add_argument(
        "--error-rate", type=float, default=0.0,
        help="fraction of rows (0-1) that get one injected validation error (default: 0)",
    )
    parser.add_argument(
        "--existing-ids", metavar="FILE",
        help="existing Providers (Unique ID[,NPI] per line); the first rows update them, the rest are new",
    )
    args = parser.parse_args()
    if args.rows < 0:
        parser.error("--rows must be >= 0")
    if not 0.0 <= args.error_rate <= 1.0:
        parser.error("--error-rate must be between 0 and 1")
    return args


def row_label(row: dict) -> str:
    return row["Provider Unique ID"] or f"NPI {row['Individual NPI'] or '(none)'}"


def main():
    args = parse_args()
    if args.seed is not None:
        random.seed(args.seed)

    existing = read_existing_ids(args.existing_ids) if args.existing_ids else []
    if len(existing) > args.rows:
        print(f"Using {args.rows} of {len(existing)} existing Providers.", file=sys.stderr)

    out = open(args.output, "w", newline="", encoding="utf-8") if args.output else sys.stdout
    injected = []
    try:
        writer = csv.DictWriter(out, fieldnames=HEADERS, lineterminator="\n")
        writer.writeheader()
        for i in range(args.rows):
            row = generate_row(i + 1, existing[i] if i < len(existing) else None)
            if random.random() < args.error_rate:
                description = random.choice(ERROR_INJECTORS)(row)
                # +2: 1-based line numbers plus the header line
                injected.append((i + 2, row_label(row), description))
            writer.writerow(row)
    finally:
        if out is not sys.stdout:
            out.close()

    if injected:
        print(f"Injected {len(injected)} error(s):", file=sys.stderr)
        for line_no, label, description in injected:
            print(f"  line {line_no} ({label}): {description}", file=sys.stderr)


if __name__ == "__main__":
    main()
