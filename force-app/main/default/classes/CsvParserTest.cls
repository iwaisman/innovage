@IsTest
private class CsvParserTest {

    private static final String CSV = 'a,b\r\n1,2\r\n"multi\r\nline",3\r\n4,"5"\r\n';

    private static CsvParser.Options options() {
        return new CsvParser.Options(false, true);
    }

    @IsTest
    static void shouldKeepLineBreakInsideRecord_WhenFieldQuoted() {
        Test.startTest();
        List<List<String>> records = CsvParser.parse(CSV, options());
        Test.stopTest();

        Assert.areEqual(4, records.size(), 'Header plus three records');
        Assert.areEqual(new List<String>{ 'multi\r\nline', '3' }, records[2], 'A quoted line break stays inside its record');
        Assert.areEqual(new List<String>{ '4', '5' }, records[3], 'Quotes are removed');
    }

    @IsTest
    static void shouldSkipBom_WhenPresent() {
        Test.startTest();
        List<List<String>> records = CsvParser.parse('﻿h\r\nx\r\n', options());
        Test.stopTest();

        Assert.areEqual('h', records[0][0], 'BOM is not part of the first header');
    }

    @IsTest
    static void shouldIgnoreBlankLines_WhenConfigured() {
        Test.startTest();
        List<List<String>> records = CsvParser.parse('h\r\nx\r\n\r\n\r\n', options());
        Test.stopTest();

        Assert.areEqual(2, records.size(), 'Blank lines are ignored');
    }

    @IsTest
    static void shouldReportOffset_WhenRecordMalformed() {
        String csv = 'h\r\nok\r\nbad"quote\r\n';

        Test.startTest();
        try {
            CsvParser.parse(csv, options());
            Assert.fail('Expected CsvParseException');
        } catch (CsvParser.CsvParseException e) {
            Assert.isTrue(e.getMessage().contains('offset: ' + csv.indexOf('"')), 'Message gives the offset: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldTrimHeaders_WhenConvertingHeaderRecord() {
        Test.startTest();
        List<String> headers = CsvParser.toHeaders(new List<String>{ ' a ', 'b' });
        Test.stopTest();

        Assert.areEqual(new List<String>{ 'a', 'b' }, headers, 'Headers are trimmed');
    }

    @IsTest
    static void shouldThrow_WhenHeadersDuplicated() {
        Test.startTest();
        try {
            CsvParser.toHeaders(new List<String>{ 'a', ' a' });
            Assert.fail('Expected CsvParseException');
        } catch (CsvParser.CsvParseException e) {
            Assert.isTrue(e.getMessage().contains('Duplicate'), 'Message names the problem');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldMapRowsToHeaders_WhenParsingWithHeaders() {
        Test.startTest();
        CsvParser.ParsedWithHeaders parsed = CsvParser.parseWithHeaders(CSV);
        Test.stopTest();

        Assert.areEqual(new List<String>{ 'a', 'b' }, parsed.headers, 'Header record');
        Assert.areEqual(3, parsed.rows.size(), 'Data rows');
        Assert.areEqual('5', parsed.rows[2].get('b'), 'Values keyed by header');
    }

    @IsTest
    static void shouldThrow_WhenRowHasWrongColumnCountWithHeaders() {
        Test.startTest();
        try {
            CsvParser.parseWithHeaders('a,b\r\n1\r\n');
            Assert.fail('Expected CsvParseException');
        } catch (CsvParser.CsvParseException e) {
            Assert.isTrue(e.getMessage().contains('fields'), 'Message explains the mismatch: ' + e.getMessage());
        }
        Test.stopTest();
    }
}
