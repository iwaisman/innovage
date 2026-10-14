public with sharing class CsvParser {

    /**
     * Parser configuration.
     *
     * Defaults:
     *   - hasHeader = false
     *   - ignoreBlankLines = false
     *   - delimiter = ','
     *   - stripUtf8Bom = true
     */
    public class Options {
        public Boolean hasHeader { get; set; }
        public Boolean ignoreBlankLines { get; set; }
        public String delimiter { get; set; }
        public Boolean stripUtf8Bom { get; set; }

        public Options() {
            hasHeader = false;
            ignoreBlankLines = false;
            delimiter = ',';
            stripUtf8Bom = true;
        }

        public Options(Boolean hasHeader, Boolean ignoreBlankLines) {
            this();
            this.hasHeader = hasHeader;
            this.ignoreBlankLines = ignoreBlankLines;
        }
    }


    /**
     * Result of parsing CSV without headers.
     */
    public class ParsedRows {
        public List<List<String>> rows { get; private set; }

        public ParsedRows() {
            rows = new List<List<String>>();
        }
    }


    /**
     * Result of parsing CSV with headers.
     *
     * headers contains the first CSV record.
     *
     * Each subsequent record is represented as:
     *
     *     Map<header, value>
     */
    public class ParsedWithHeaders {
        public List<String> headers { get; private set; }
        public List<Map<String, String>> rows { get; private set; }

        public ParsedWithHeaders() {
            headers = new List<String>();
            rows = new List<Map<String, String>>();
        }
    }


    /**
     * Result of parsing part of a CSV (see parseChunk).
     *
     * nextOffset is the character offset of the first record not yet
     * parsed. It always falls on a record boundary, so passing it back to
     * parseChunk resumes exactly where this chunk stopped.
     */
    public class Chunk {
        public List<List<String>> records { get; private set; }
        public Integer nextOffset { get; private set; }
        public Boolean isEndOfInput { get; private set; }

        private Chunk(List<List<String>> records, Integer nextOffset, Boolean isEndOfInput) {
            this.records = records;
            this.nextOffset = nextOffset;
            this.isEndOfInput = isEndOfInput;
        }
    }


    public class CsvParseException extends Exception {}


    /*
     * Parser states.
     *
     * FIELD_START:
     *     We are at the beginning of a field.
     *
     * IN_UNQUOTED_FIELD:
     *     We are reading an ordinary field.
     *
     * IN_QUOTED_FIELD:
     *     We are inside a quoted field.
     *
     * AFTER_CLOSING_QUOTE:
     *     We encountered the closing quote of a quoted field.
     *     Only delimiter, record terminator, or EOF are legal next.
     */
    private static final Integer FIELD_START = 0;
    private static final Integer IN_UNQUOTED_FIELD = 1;
    private static final Integer IN_QUOTED_FIELD = 2;
    private static final Integer AFTER_CLOSING_QUOTE = 3;


    /**
     * Convenience method for the most common use case:
     *
     *     - first record is the header
     *     - completely blank lines are ignored
     *     - comma is the delimiter
     *     - UTF-8 BOM is stripped if present
     */
    public static ParsedWithHeaders parseWithHeaders(String csv) {
        Options options = new Options(true, true);
        return parseWithHeaders(csv, options);
    }


    /**
     * Parse CSV with headers.
     *
     * The first parsed record becomes the headers.
     *
     * Every subsequent record must contain exactly the same number
     * of fields as the header record.
     */
    public static ParsedWithHeaders parseWithHeaders(
        String csv,
        Options options
    ) {
        if (options == null) {
            options = new Options();
        }

        options.hasHeader = true;

        List<List<String>> records = parseRecords(csv, options);

        ParsedWithHeaders result = new ParsedWithHeaders();

        if (records.isEmpty()) {
            return result;
        }

        result.headers.addAll(toHeaders(records[0]));

        for (Integer rowIndex = 1; rowIndex < records.size(); rowIndex++) {
            List<String> values = records[rowIndex];

            if (values.size() != result.headers.size()) {
                throw new CsvParseException(
                    'CSV row ' + (rowIndex + 1) +
                    ' contains ' + values.size() +
                    ' fields, but the header contains ' +
                    result.headers.size() + ' fields.'
                );
            }

            Map<String, String> row = new Map<String, String>();

            for (Integer columnIndex = 0;
                 columnIndex < result.headers.size();
                 columnIndex++) {

                row.put(
                    result.headers[columnIndex],
                    values[columnIndex]
                );
            }

            result.rows.add(row);
        }

        return result;
    }


    /**
     * Parse CSV using the supplied options.
     *
     * This method returns raw records. If hasHeader is true, the
     * first record is still returned as a normal List<String>.
     *
     * Use parseWithHeaders() when Map<String, String> rows are desired.
     */
    public static List<List<String>> parse(
        String csv,
        Options options
    ) {
        if (options == null) {
            options = new Options();
        }

        return parseRecords(csv, options);
    }


    /**
     * Parse at most maxRecords records, starting at a character offset.
     *
     * Lets a large CSV be parsed across several transactions: each call
     * parses one chunk, and the next call resumes from chunk.nextOffset.
     * Offsets index the whole csv string, so parse error offsets are
     * absolute too. A UTF-8 BOM is only stripped when startOffset is 0.
     *
     * @param csv The complete CSV text
     * @param startOffset Offset of the first character to parse; 0, or a nextOffset from a previous chunk
     * @param maxRecords Maximum number of records to return (at least 1)
     * @param options Parser options; hasHeader is ignored (the header is just the first record)
     * @return The records and where to resume
     * @throws CsvParseException if the CSV is malformed or the arguments are invalid
     * @example
     * CsvParser.Chunk header = CsvParser.parseChunk(csv, 0, 1, options);
     * CsvParser.Chunk rows = CsvParser.parseChunk(csv, header.nextOffset, 200, options);
     */
    public static Chunk parseChunk(String csv, Integer startOffset, Integer maxRecords, Options options) {
        if (startOffset == null || startOffset < 0) {
            throw new CsvParseException('Start offset must be zero or positive.');
        }
        if (maxRecords == null || maxRecords < 1) {
            throw new CsvParseException('Maximum records must be at least 1.');
        }
        return parseFrom(csv, options ?? new Options(), startOffset, maxRecords);
    }


    /**
     * Trim a header record and check it can be used as map keys.
     *
     * @param record The first record of a CSV
     * @return The trimmed header names
     * @throws CsvParseException if two headers have the same name
     */
    public static List<String> toHeaders(List<String> record) {
        List<String> headers = new List<String>();
        for (String header : record) {
            headers.add(header.trim());
        }
        validateHeaders(headers);
        return headers;
    }


    /**
     * Parse the whole CSV into records.
     */
    private static List<List<String>> parseRecords(
        String csv,
        Options options
    ) {
        return parseFrom(csv, options, 0, null).records;
    }


    /**
     * Parse records from startOffset until the input ends or maxRecords
     * records (null = no limit) have been parsed.
     *
     * This implementation deliberately does not use String.split().
     * A CSV record is not necessarily a physical line because a
     * quoted field may contain CR, LF, or CRLF.
     */
    private static Chunk parseFrom(
        String csv,
        Options options,
        Integer startOffset,
        Integer maxRecords
    ) {
        List<List<String>> records = new List<List<String>>();

        validateOptions(options);

        if (csv == null || startOffset >= csv.length()) {
            return new Chunk(records, startOffset, true);
        }

        Integer i = startOffset;

        /*
         * The BOM is skipped rather than removed with substring(), so
         * offsets keep indexing the caller's string.
         */
        if (startOffset == 0 &&
            options.stripUtf8Bom &&
            csv.substring(0, 1) == '\uFEFF') {

            i = 1;
        }

        String delimiter = options.delimiter;

        List<String> currentRecord = new List<String>();
        String currentField = '';

        Integer state = FIELD_START;

        /*
         * recordStarted distinguishes:
         *
         *     <empty physical line>
         *
         * from:
         *
         *     ,
         *
         * and:
         *
         *     ""
         *
         *
         * This is important because ignoreBlankLines must only ignore
         * lines containing zero characters. A line containing commas
         * represents actual CSV fields and must never be discarded.
         */
        Boolean recordStarted = false;

        Integer length = csv.length();

        while (i < length) {
            String ch = csv.substring(i, i + 1);

            /*
             * ---------------------------------------------------------
             * Inside a quoted field
             * ---------------------------------------------------------
             */
            if (state == IN_QUOTED_FIELD) {

                if (ch == '"') {
                    /*
                     * RFC 4180 escaping:
                     *
                     *     "" -> "
                     */
                    if (i + 1 < length &&
                        csv.substring(i + 1, i + 2) == '"') {

                        currentField += '"';
                        i += 2;
                        continue;
                    }

                    /*
                     * This quote closes the quoted field.
                     */
                    state = AFTER_CLOSING_QUOTE;
                    i++;
                    continue;
                }

                /*
                 * CR and LF are ordinary characters while inside
                 * a quoted field. They become part of the field value.
                 *
                 * In particular, CRLF remains CRLF.
                 */
                currentField += ch;
                i++;
                continue;
            }


            /*
             * ---------------------------------------------------------
             * Immediately after a closing quote
             * ---------------------------------------------------------
             */
            if (state == AFTER_CLOSING_QUOTE) {

                /*
                 * A delimiter terminates the field.
                 */
                if (ch == delimiter) {
                    currentRecord.add(currentField);

                    currentField = '';
                    state = FIELD_START;
                    recordStarted = true;

                    i++;
                    continue;
                }

                /*
                 * CR or LF terminates the record.
                 */
                if (ch == '\r' || ch == '\n') {
                    currentRecord.add(currentField);

                    addRecordIfAppropriate(
                        records,
                        currentRecord,
                        recordStarted,
                        options.ignoreBlankLines
                    );

                    currentRecord = new List<String>();
                    currentField = '';
                    state = FIELD_START;
                    recordStarted = false;

                    i = consumeLineEnding(csv, i);

                    if (maxRecords != null && records.size() >= maxRecords) {
                        return new Chunk(records, i, i >= length);
                    }
                    continue;
                }

                /*
                 * Anything else after a closing quote is invalid.
                 *
                 * For example:
                 *
                 *     "hello"x
                 *
                 *     "hello"world
                 */
                throw malformedCsv(
                    i,
                    'Unexpected character after closing quote.'
                );
            }


            /*
             * ---------------------------------------------------------
             * Beginning of a field
             * ---------------------------------------------------------
             */
            if (state == FIELD_START) {

                /*
                 * A quote is only legal at the beginning of a field.
                 */
                if (ch == '"') {
                    state = IN_QUOTED_FIELD;
                    recordStarted = true;
                    i++;
                    continue;
                }

                /*
                 * Delimiter at the beginning means an empty field.
                 *
                 * Example:
                 *
                 *     ,ABC
                 *
                 * produces:
                 *
                 *     ['', 'ABC']
                 */
                if (ch == delimiter) {
                    currentRecord.add('');
                    recordStarted = true;
                    i++;
                    continue;
                }

                /*
                 * Record terminator.
                 *
                 * If recordStarted is false, this is a completely
                 * blank physical line.
                 */
                if (ch == '\r' || ch == '\n') {
                    if (recordStarted) {
                        currentRecord.add(currentField);

                        addRecordIfAppropriate(
                            records,
                            currentRecord,
                            true,
                            options.ignoreBlankLines
                        );
                    } else {
                        /*
                         * With ignoreBlankLines = false, represent an
                         * empty physical line as a one-field empty record.
                         *
                         * With ignoreBlankLines = true, discard it.
                         */
                        if (!options.ignoreBlankLines) {
                            currentRecord.add('');
                            records.add(currentRecord);
                        }
                    }

                    currentRecord = new List<String>();
                    currentField = '';
                    state = FIELD_START;
                    recordStarted = false;

                    i = consumeLineEnding(csv, i);

                    if (maxRecords != null && records.size() >= maxRecords) {
                        return new Chunk(records, i, i >= length);
                    }
                    continue;
                }

                /*
                 * Any other character begins an unquoted field.
                 *
                 * Whitespace is data. We intentionally do not trim it.
                 */
                currentField += ch;
                state = IN_UNQUOTED_FIELD;
                recordStarted = true;

                i++;
                continue;
            }


            /*
             * ---------------------------------------------------------
             * Inside an unquoted field
             * ---------------------------------------------------------
             */
            if (state == IN_UNQUOTED_FIELD) {

                /*
                 * Delimiter terminates the field.
                 */
                if (ch == delimiter) {
                    currentRecord.add(currentField);

                    currentField = '';
                    state = FIELD_START;
                    recordStarted = true;

                    i++;
                    continue;
                }

                /*
                 * CR or LF terminates the record.
                 */
                if (ch == '\r' || ch == '\n') {
                    currentRecord.add(currentField);

                    addRecordIfAppropriate(
                        records,
                        currentRecord,
                        true,
                        options.ignoreBlankLines
                    );

                    currentRecord = new List<String>();
                    currentField = '';
                    state = FIELD_START;
                    recordStarted = false;

                    i = consumeLineEnding(csv, i);

                    if (maxRecords != null && records.size() >= maxRecords) {
                        return new Chunk(records, i, i >= length);
                    }
                    continue;
                }

                /*
                 * Quotes are not legal inside an unquoted field.
                 *
                 * This intentionally rejects:
                 *
                 *     abc"def
                 *
                 * rather than silently interpreting it.
                 */
                if (ch == '"') {
                    throw malformedCsv(
                        i,
                        'Unexpected quote inside an unquoted field.'
                    );
                }

                currentField += ch;
                i++;
                continue;
            }


            /*
             * Defensive fallback. Every state should have been handled
             * above.
             */
            throw malformedCsv(
                i,
                'Parser entered an invalid state.'
            );
        }


        /*
         * EOF while inside a quoted field is invalid.
         */
        if (state == IN_QUOTED_FIELD) {
            throw malformedCsv(
                length,
                'CSV ended while inside a quoted field.'
            );
        }


        /*
         * A closing quote at EOF is valid:
         *
         *     "hello"
         *
         * becomes one field.
         *
         * Likewise, an unquoted field without a final newline is valid.
         */
        if (state == AFTER_CLOSING_QUOTE ||
            state == IN_UNQUOTED_FIELD) {

            currentRecord.add(currentField);

            addRecordIfAppropriate(
                records,
                currentRecord,
                true,
                options.ignoreBlankLines
            );
        }
        else if (state == FIELD_START && recordStarted) {
            /*
             * This occurs for a trailing delimiter:
             *
             *     A,B,
             *
             * The final empty field must be retained.
             */
            currentRecord.add(currentField);

            addRecordIfAppropriate(
                records,
                currentRecord,
                true,
                options.ignoreBlankLines
            );
        }

        return new Chunk(records, length, true);
    }


    /**
     * Add a completed record unless it is a completely blank physical
     * line and blank lines are configured to be ignored.
     *
     * recordStarted is deliberately used instead of checking whether
     * the parsed values are empty:
     *
     *     ,       -> keep
     *     ,,      -> keep
     *     ""      -> keep
     *     " "     -> keep
     *     <blank> -> optionally ignore
     */
    private static void addRecordIfAppropriate(
        List<List<String>> records,
        List<String> record,
        Boolean recordStarted,
        Boolean ignoreBlankLines
    ) {
        if (ignoreBlankLines && !recordStarted) {
            return;
        }

        records.add(record);
    }


    /**
     * Consume CRLF as one record terminator.
     *
     * CR by itself and LF by itself are also accepted.
     */
    private static Integer consumeLineEnding(
        String csv,
        Integer index
    ) {
        String ch = csv.substring(index, index + 1);

        if (ch == '\r' &&
            index + 1 < csv.length() &&
            csv.substring(index + 1, index + 2) == '\n') {

            return index + 2;
        }

        return index + 1;
    }


    /**
     * Validate parser configuration.
     */
    private static void validateOptions(Options options) {
        if (options == null) {
            throw new CsvParseException(
                'CSV parser options cannot be null.'
            );
        }

        if (String.isBlank(options.delimiter)) {
            throw new CsvParseException(
                'CSV delimiter cannot be blank.'
            );
        }

        /*
         * This parser intentionally supports a single-character
         * delimiter. RFC 4180 specifies comma, and allowing another
         * single character is useful for TSV/pipe-delimited variants.
         */
        if (options.delimiter.length() != 1) {
            throw new CsvParseException(
                'CSV delimiter must be exactly one character.'
            );
        }

        if (options.delimiter == '"' ||
            options.delimiter == '\r' ||
            options.delimiter == '\n') {

            throw new CsvParseException(
                'CSV delimiter cannot be a quote or line terminator.'
            );
        }

        if (options.hasHeader == null) {
            options.hasHeader = false;
        }

        if (options.ignoreBlankLines == null) {
            options.ignoreBlankLines = false;
        }

        if (options.stripUtf8Bom == null) {
            options.stripUtf8Bom = true;
        }
    }


    /**
     * Validate header names.
     *
     * Maps cannot represent duplicate keys without losing data, so
     * duplicate headers are treated as malformed input.
     *
     * Empty headers are allowed because RFC 4180 does not prohibit them.
     */
    private static void validateHeaders(List<String> headers) {
        Set<String> seen = new Set<String>();

        for (Integer i = 0; i < headers.size(); i++) {
            String header = headers[i];

            if (seen.contains(header)) {
                throw new CsvParseException(
                    'Duplicate CSV header "' +
                    header +
                    '" at column ' +
                    (i + 1) +
                    '.'
                );
            }

            seen.add(header);
        }
    }


    /**
     * Construct a useful parse exception including the zero-based
     * character offset.
     */
    private static CsvParseException malformedCsv(
        Integer index,
        String message
    ) {
        return new CsvParseException(
            message +
            ' Character offset: ' +
            index +
            '.'
        );
    }
}