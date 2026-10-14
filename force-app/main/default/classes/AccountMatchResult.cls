/**
 * Outcome of matching one incoming roster row against existing Account records.
 *
 * Produced by the record-type-specific matchers (for example ProviderMatcher).
 * Exactly one Outcome applies to each row; UNIQUE_MATCH and NO_MATCH are the
 * only outcomes that allow the row to be ingested.
 */
public inherited sharing class AccountMatchResult {

    public enum Outcome {
        UNIQUE_MATCH,        // exactly one Account matches all supplied keys
        NO_MATCH,            // no Account matches; the row describes a new Account
        NO_KEY_VALUES,       // no usable key values were supplied
        MALFORMED_UNIQUE_ID, // the InnovAge Unique ID is not well formed for this record type
        MALFORMED_NPI,       // the NPI is not 10 digits with a valid check digit
        UNKNOWN_UNIQUE_ID,   // the InnovAge Unique ID is well formed but identifies no Account
        MULTIPLE_MATCHES,    // the supplied keys identify more than one Account
        KEY_MISMATCH         // one Account matched, but another supplied key disagrees with it
    }

    /**
     * A key value supplied in the input that disagrees with the matched Account.
     */
    public class KeyMismatch {
        public String inputValue { get; private set; }
        public String accountValue { get; private set; }

        public KeyMismatch(String inputValue, String accountValue) {
            this.inputValue = inputValue;
            this.accountValue = accountValue;
        }
    }

    public Outcome outcome { get; private set; }

    /** The matched Account (UNIQUE_MATCH), or the Account whose keys disagree (KEY_MISMATCH). */
    public Account account { get; private set; }

    /** Every Account identified by the supplied keys (MULTIPLE_MATCHES). */
    public List<Account> candidates { get; private set; }

    /** Key field API name => the disagreeing values (KEY_MISMATCH). */
    public Map<String, KeyMismatch> keyMismatchesByField { get; private set; }

    /** Human-readable explanation of an error outcome; null for UNIQUE_MATCH and NO_MATCH. */
    public String message { get; private set; }

    private AccountMatchResult(Outcome outcome, String message) {
        this.outcome = outcome;
        this.message = message;
        this.candidates = new List<Account>();
        this.keyMismatchesByField = new Map<String, KeyMismatch>();
    }

    /**
     * @return true when the row must not be ingested.
     */
    public Boolean isError() {
        // Qualified: inside instance methods the "outcome" property shadows the Outcome enum
        return outcome != AccountMatchResult.Outcome.UNIQUE_MATCH && outcome != AccountMatchResult.Outcome.NO_MATCH;
    }

    /**
     * @param account The single Account matched by the supplied keys
     * @return A UNIQUE_MATCH result
     */
    public static AccountMatchResult uniqueMatch(Account account) {
        AccountMatchResult result = new AccountMatchResult(Outcome.UNIQUE_MATCH, null);
        result.account = account;
        return result;
    }

    /**
     * @return A NO_MATCH result
     */
    public static AccountMatchResult noMatch() {
        return new AccountMatchResult(Outcome.NO_MATCH, null);
    }

    /**
     * @param outcome An error outcome that carries no records (for example NO_KEY_VALUES)
     * @param message Explanation of the error
     * @return An error result
     */
    public static AccountMatchResult error(Outcome outcome, String message) {
        return new AccountMatchResult(outcome, message);
    }

    /**
     * @param candidates The Accounts identified by the supplied keys
     * @param message Explanation of the error
     * @return A MULTIPLE_MATCHES result
     */
    public static AccountMatchResult multipleMatches(List<Account> candidates, String message) {
        AccountMatchResult result = new AccountMatchResult(Outcome.MULTIPLE_MATCHES, message);
        result.candidates.addAll(candidates);
        return result;
    }

    /**
     * @param account The Account matched by one key
     * @param keyMismatchesByField The other keys that disagree with it
     * @param message Explanation of the error
     * @return A KEY_MISMATCH result
     */
    public static AccountMatchResult keyMismatch(
        Account account,
        Map<String, KeyMismatch> keyMismatchesByField,
        String message
    ) {
        AccountMatchResult result = new AccountMatchResult(Outcome.KEY_MISMATCH, message);
        result.account = account;
        result.keyMismatchesByField.putAll(keyMismatchesByField);
        return result;
    }
}
