#!/usr/bin/env python3
"""Generate a synthetic provider roster CSV for testing roster file validation.

Uses only the standard library. All generated identifiers are deliberately
non-real: SSNs use the 9xx area (never issued), phones use the 555-01xx
fictional range, and emails use example.com. NPIs are random but carry a
valid Luhn check digit so they pass format validation.

Exactly the columns intake reads are generated (those of
docs/specs/provider-file-mapping.csv). Without --error-rate every row is valid
and should be ingested with no Issues. Gender, pronouns and languages use values the org's picklists accept; secondary languages are
separated by ";" (ProviderCsvMapping.MULTI_PICKLIST_SEPARATOR). Specialties are
written as "<label>:<NUCC taxonomy code>" with codes that exist in the sandbox's
verifiable__VfiNUCCTaxonomy__c table (ProviderCsvMapping.SPECIALTY_CODE_SEPARATOR).
Credentialing dates are in the past (a date of today or later is invalid), and
the gender-affirming-care column is Yes or No.

Provider Unique ID is left blank: intake requires a supplied Unique ID to
identify an existing Provider, so generated rows describe new Providers and are
matched by NPI. To exercise the update path, pass --existing-ids with real
Provider keys from the org; those rows become updates of existing Providers.

With --error-rate, each affected row gets one injected problem, and the expected
Issue code is printed to stderr. Some problems only apply to new Providers
(e.g. MISSING_LAST_NAME) or to existing ones (e.g. LAST_NAME_DIFFERS,
ADDRESS_NOT_UPDATED); an injector is only chosen for a row it applies to.

Examples:
    python3 scripts/generate_roster_csv.py --rows 100 -o roster.csv
    python3 scripts/generate_roster_csv.py --rows 500 --error-rate 0.1 --seed 42 > roster.csv
    python3 scripts/generate_roster_csv.py --rows 500 --existing-ids providers.csv -o roster.csv

The --existing-ids file has one Provider per line: the InnovAge Unique ID,
optionally followed by the Provider's NPI and Last Name (comma separated).
Without the Last Name, update rows get a random one, which raises warning
LAST_NAME_DIFFERS. Export it with:
    sf data query -o innovage -r csv \\
        -q "SELECT InnovAge_Unique_ID__c, NPI__c, LastName FROM Account WHERE RecordType.DeveloperName = 'Provider' LIMIT 100"
(a header line, if present, is skipped).
"""

import argparse
import csv
import random
import re
import sys
from datetime import date, timedelta

HEADERS = [
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
    "Secondary Provider Specialty",
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
# Values of the org's PersonGender and PersonPronouns picklists (blank = not given).
GENDERS = [
    ("Female", "She/Her"),
    ("Female", "She/They"),
    ("Male", "He/Him"),
    ("Male", "He/They"),
    ("Other", "They/Them"),
    ("Other", "Not Listed"),
    ("Unknown", ""),
    ("", ""),
]
# All are values of the org's language picklists (Primary_Language__c, Secondary_Languages__c).
LANGUAGES = [
    "English", "Spanish", "French", "Vietnamese", "Mandarin", "Russian",
    "Arabic", "Korean", "Tagalog", "Amharic", "Polish", "Hindi",
]
# Separates secondary languages; must match ProviderCsvMapping.MULTI_PICKLIST_SEPARATOR.
LANGUAGE_SEPARATOR = ";"
# (label, NUCC taxonomy code); every code exists in the innovage sandbox's NUCC taxonomy.
SPECIALTIES = [
    ("Internal Medicine Physician", "207R00000X"),
    ("Family Medicine Physician", "207Q00000X"),
    ("Geriatric Medicine (Family Medicine) Physician", "207QG0300X"),
    ("Cardiovascular Disease Physician", "207RC0000X"),
    ("Psychiatry Physician", "2084P0800X"),
    ("Podiatrist", "213E00000X"),
    ("Physical Therapist", "225100000X"),
    ("Occupational Therapist", "225X00000X"),
    ("Clinical Social Worker", "1041C0700X"),
    ("Registered Nurse", "163W00000X"),
    ("Endocrinology, Diabetes & Metabolism Physician", "207RE0101X"),
    ("Neurology Physician", "2084N0400X"),
    ("Family Nurse Practitioner", "363LF0000X"),
    ("Physician Assistant", "363A00000X"),
]
# Separates a specialty's label from its code; must match ProviderCsvMapping.SPECIALTY_CODE_SEPARATOR.
SPECIALTY_SEPARATOR = ":"


def specialty_value(specialty) -> str:
    label, code = specialty
    return f"{label}{SPECIALTY_SEPARATOR}{code}"
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
    """A valid row for a new Provider, or an update of an existing one ((unique_id, npi, last_name) in existing)."""
    today = date.today()
    yesterday = today - timedelta(days=1)
    first = random.choice(FIRST_NAMES)
    # Last Name is never changed on an existing Provider; a different one only raises LAST_NAME_DIFFERS.
    last = existing[2] if existing and existing[2] else random.choice(LAST_NAMES)
    gender, pronouns = random.choice(GENDERS)
    primary_language = random.choice(LANGUAGES[:3]) if random.random() < 0.9 else random.choice(LANGUAGES)
    secondary = random.sample([l for l in LANGUAGES if l != primary_language], k=random.randint(0, 2))
    primary_specialty = random.choice(SPECIALTIES)
    secondary_specialty = random.choice(
        [None, None] + [s for s in SPECIALTIES if s != primary_specialty]
    )

    mailing = generate_address()
    billing = mailing if random.random() < 0.5 else generate_address()

    dob = random_date(date(1950, 1, 1), date(1995, 12, 31))
    # Credentialing dates must be strictly in the past.
    initial_cred = random_date(date(2010, 1, 1), today - timedelta(days=365))
    last_cred = random_date(initial_cred, yesterday)
    medicaid_state = mailing["state"]

    return {
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
        "Secondary Provider Language(s)": LANGUAGE_SEPARATOR.join(secondary),
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
        "Primary Provider Specialty": specialty_value(primary_specialty),
        "Secondary Provider Specialty": specialty_value(secondary_specialty) if secondary_specialty else "",
        "CAQH ID": f"{random.randint(10000000, 19999999)}",
        "Initial Credentialing Date": fmt(initial_cred),
        "Last Credentialing Date": fmt(last_cred),
        # An existing Provider keeps its own NPI (a different one would be a key mismatch).
        "Individual NPI": existing[1] if existing else generate_npi(),
        # Written to the Provider's HealthcareProvider (Offers_Offered_Gender_Affirming_Services__c).
        "Provider Attests to Providing Gender Affirming Care?": random.choice(["Yes", "No", "yes", "no", ""]),
        "Medicare ID": f"{medicaid_state}{random.randint(1000000, 9999999)}",
        "Medicaid ID State": medicaid_state,
        "Medicaid ID": f"{random.choice('ABCDEFGHJKLMNPRSTUVWXYZ')}{random.randint(100000, 999999)}",
    }


# Each injector mutates a valid row in place and returns (expected Issue code, short description).
# NEW / EXISTING / ANY say which rows it applies to: a new Provider (no Unique ID) or an update of
# an existing one. Invalid values are warnings (INVALID_VALUE: the value is ignored, the rest of the
# row is ingested); key problems are row errors. Codes are declared in RosterIntakeIssues.cls.
NEW, EXISTING, ANY = "new", "existing", "any"


def _is_existing(row) -> bool:
    return bool(row["Provider Unique ID"])


def _address_code(row) -> str:
    # A new Provider's invalid address part is dropped on its own; an existing Provider's
    # address is updated as a whole or not at all.
    return "ADDRESS_NOT_UPDATED" if _is_existing(row) else "INVALID_VALUE"


def _bad_npi(row):
    npi = row["Individual NPI"] or generate_npi()
    row["Individual NPI"] = npi[:9] + str((int(npi[9]) + 1) % 10)
    return "MALFORMED_NPI", "NPI with invalid check digit"


def _short_npi(row):
    row["Individual NPI"] = (row["Individual NPI"] or generate_npi())[:8]
    return "MALFORMED_NPI", "NPI with wrong length"


def _no_keys(row):
    row["Provider Unique ID"] = ""
    row["Individual NPI"] = ""
    return "NO_KEY_VALUES", "neither Provider Unique ID nor Individual NPI"


def _bad_unique_id(row):
    row["Provider Unique ID"] = random.choice(["PRV-000123", "P12345", "PG000000001abc"])
    return "MALFORMED_UNIQUE_ID", "malformed Provider Unique ID"


def _missing_last_name(row):
    row["Last Name"] = ""
    return "MISSING_LAST_NAME", "new Provider without a Last Name"


def _last_name_differs(row):
    row["Last Name"] = row["Last Name"] + "-Changed"
    return "LAST_NAME_DIFFERS", "Last Name differs from the stored one (not updated)"


def _bad_dob(row):
    row["Date of Birth"] = random.choice(["13/45/1980", "1980-04-17", "not a date"])
    return "INVALID_VALUE", "malformed Date of Birth"


def _future_dob(row):
    row["Date of Birth"] = fmt(date.today() + timedelta(days=random.randint(1, 3650)))
    return "INVALID_VALUE", "Date of Birth in the future"


def _bad_ssn(row):
    row["Social Security Number"] = random.choice(["123-45-678", "12345678A", "000-00-0000"])
    return "INVALID_VALUE", "malformed SSN"


def _bad_email(row):
    row["Provider Email"] = row["Provider Email"].replace("@", "")
    return "INVALID_VALUE", "invalid email"


def _bad_phone(row):
    row["Provider Phone"] = random.choice(["555-0100", "(303) 555-01", "call me"])
    return "INVALID_VALUE", "Provider Phone not a 10-digit US number"


def _bad_gender(row):
    row["Gender Identification"] = random.choice(["Non-binary", "Prefer not to say", "F"])
    return "INVALID_VALUE", "Gender Identification not an allowed value"


def _bad_pronouns(row):
    row["Pronouns"] = random.choice(["Ze/Zir", "she", "Any"])
    return "INVALID_VALUE", "Pronouns not an allowed value"


def _bad_language(row):
    row["Primary Provider Language"] = random.choice(["Klingon", "Eng", "Español"])
    return "INVALID_VALUE", "Primary Provider Language not an allowed value"


def _bad_secondary_languages(row):
    row["Secondary Provider Language(s)"] = random.choice([
        "Spanish, French",  # wrong separator: read as one unknown language
        LANGUAGE_SEPARATOR.join(["Spanish", "Elvish"]),  # one unknown language drops the whole cell
    ])
    return "INVALID_VALUE", "Secondary Provider Language(s) with an unknown language or the wrong separator"


def _future_credentialing(row):
    column = random.choice(["Initial Credentialing Date", "Last Credentialing Date"])
    # Today counts as not in the past.
    row[column] = fmt(date.today() + timedelta(days=random.randint(0, 365)))
    return "INVALID_VALUE", f"{column} today or in the future"


def _bad_credentialing(row):
    column = random.choice(["Initial Credentialing Date", "Last Credentialing Date"])
    row[column] = random.choice(["2020-05-01", "02/30/2021", "last spring"])
    return "INVALID_VALUE", f"malformed {column}"


def _bad_gender_affirming(row):
    row["Provider Attests to Providing Gender Affirming Care?"] = random.choice(["Y", "Maybe", "True"])
    return "INVALID_VALUE", "Gender Affirming Care not Yes or No"


def _bad_specialty(row):
    row["Primary Provider Specialty"] = random.choice([
        f"Made-up Specialty{SPECIALTY_SEPARATOR}999999999X",  # unknown code
        "Cardiology",  # no separator: read as the code "Cardiology", which is unknown
    ])
    return "UNKNOWN_SPECIALTY", "Primary Provider Specialty with an unknown NUCC code"


def _bad_state(row):
    row["Provider Mailing State"] = random.choice(["Colorado", "XX", "C0"])
    return _address_code(row), "invalid Mailing State"


def _bad_zip(row):
    row["Provider Mailing Zip"] = random.choice(["8020", "802021", "ABCDE"])
    return _address_code(row), "invalid Mailing Zip"


def _blank_address_part(row):
    prefix = random.choice(["Provider Mailing", "Provider Billing"])
    column = random.choice([f"{prefix} City", f"{prefix} State", f"{prefix} Zip"])
    row[column] = ""
    return "ADDRESS_NOT_UPDATED", f"blank {column} (cannot overwrite the stored value)"


def _line2_without_line1(row):
    prefix = random.choice(["Provider Mailing", "Provider Billing"])
    row[f"{prefix} Address Line 1"] = ""
    row[f"{prefix} Address Line 2"] = f"Suite {random.randint(100, 999)}"
    return "ADDRESS_NOT_UPDATED", f"{prefix} Address Line 2 without Line 1"


ERROR_INJECTORS = [
    (_bad_npi, ANY), (_short_npi, ANY), (_no_keys, ANY), (_bad_unique_id, ANY),
    (_missing_last_name, NEW), (_last_name_differs, EXISTING),
    (_bad_dob, ANY), (_future_dob, ANY), (_bad_ssn, ANY), (_bad_email, ANY), (_bad_phone, ANY),
    (_bad_gender, ANY), (_bad_pronouns, ANY), (_bad_language, ANY), (_bad_secondary_languages, ANY),
    (_future_credentialing, ANY), (_bad_credentialing, ANY), (_bad_gender_affirming, ANY),
    (_bad_specialty, ANY),
    (_bad_state, ANY), (_bad_zip, ANY), (_blank_address_part, EXISTING), (_line2_without_line1, EXISTING),
]


def inject_error(row) -> tuple:
    """Applies one random injector that fits the row; returns (code, description)."""
    kind = EXISTING if _is_existing(row) else NEW
    injector = random.choice([f for f, applies_to in ERROR_INJECTORS if applies_to in (ANY, kind)])
    return injector(row)


def read_existing_ids(path: str) -> list:
    """(unique_id, npi, last_name) tuples from --existing-ids; npi and last_name are "" when not given."""
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
            fields += [""] * (3 - len(fields))
            existing.append((unique_id, fields[1], fields[2]))
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
        help="existing Providers (Unique ID[,NPI[,Last Name]] per line); the first rows update them, the rest are new",
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
                # Label the row before the injector can blank its keys.
                label = row_label(row)
                code, description = inject_error(row)
                # +2: 1-based line numbers plus the header line
                injected.append((i + 2, label, code, description))
            writer.writerow(row)
    finally:
        if out is not sys.stdout:
            out.close()

    if injected:
        print(f"Injected {len(injected)} problem(s), with the expected Issue code:", file=sys.stderr)
        for line_no, label, code, description in injected:
            print(f"  line {line_no} ({label}): {code} - {description}", file=sys.stderr)


if __name__ == "__main__":
    main()
