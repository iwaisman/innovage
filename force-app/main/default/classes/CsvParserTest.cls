@IsTest
private class CsvParserTest {

    private static final String CSV = 'a,b\r\n1,2\r\n"multi\r\nline",3\r\n4,"5"\r\n';

    private static CsvParser.Options options() {
        return new CsvParser.Options(false, true);
    }

    @IsTest
    static void shouldParseSameRecords_WhenParsedInChunks() {
        List<List<String>> whole = CsvParser.parse(CSV, options());

        Test.startTest();
        List<List<String>> chunked = new List<List<String>>();
        Integer offset = 0;
        Integer chunks = 0;
        Boolean atEnd = false;
        while (!atEnd) {
            CsvParser.Chunk chunk = CsvParser.parseChunk(CSV, offset, 1, options());
            chunked.addAll(chunk.records);
            offset = chunk.nextOffset;
            atEnd = chunk.isEndOfInput;
            chunks++;
        }
        Test.stopTest();

        Assert.areEqual(whole, chunked, 'Chunked parsing yields the same records');
        Assert.areEqual(4, chunks, 'One chunk per record; the last one reaches the end');
        Assert.areEqual(new List<String>{ 'multi\r\nline', '3' }, chunked[2], 'A quoted line break stays inside its record');
    }

    @IsTest
    static void shouldReportEndOfInput_WhenChunkTakesLastRecord() {
        Test.startTest();
        CsvParser.Chunk chunk = CsvParser.parseChunk(CSV, 0, 10, options());
        Test.stopTest();

        Assert.areEqual(4, chunk.records.size(), 'All records fit');
        Assert.isTrue(chunk.isEndOfInput, 'The input is exhausted');
        Assert.areEqual(CSV.length(), chunk.nextOffset, 'Next offset is the end of the input');
    }

    @IsTest
    static void shouldStopAtRecordBoundary_WhenChunkIsFull() {
        Test.startTest();
        CsvParser.Chunk first = CsvParser.parseChunk(CSV, 0, 2, options());
        CsvParser.Chunk second = CsvParser.parseChunk(CSV, first.nextOffset, 2, options());
        Test.stopTest();

        Assert.isFalse(first.isEndOfInput, 'More records follow');
        Assert.areEqual('"multi', CSV.substring(first.nextOffset, first.nextOffset + 6), 'Resumes at the next record');
        Assert.areEqual(new List<String>{ '4', '5' }, second.records[1], 'Second chunk ends with the last record');
        Assert.isTrue(second.isEndOfInput, 'Second chunk reaches the end');
    }

    @IsTest
    static void shouldSkipBom_OnlyAtStartOfInput() {
        String withBom = '﻿h\r\nx\r\n';

        Test.startTest();
        CsvParser.Chunk header = CsvParser.parseChunk(withBom, 0, 1, options());
        CsvParser.Chunk rows = CsvParser.parseChunk(withBom, header.nextOffset, 1, options());
        Test.stopTest();

        Assert.areEqual('h', header.records[0][0], 'BOM is not part of the first header');
        Assert.areEqual('x', rows.records[0][0], 'Later chunk parses normally');
    }

    @IsTest
    static void shouldReturnEmptyFinalChunk_WhenOnlyBlankLinesRemain() {
        String csv = 'h\r\nx\r\n\r\n\r\n';
        CsvParser.Chunk first = CsvParser.parseChunk(csv, 0, 2, options());

        Test.startTest();
        CsvParser.Chunk last = CsvParser.parseChunk(csv, first.nextOffset, 2, options());
        Test.stopTest();

        Assert.isTrue(last.records.isEmpty(), 'Blank lines are ignored');
        Assert.isTrue(last.isEndOfInput, 'The input is exhausted');
    }

    @IsTest
    static void shouldReportAbsoluteOffset_WhenMalformedRecordInLaterChunk() {
        String csv = 'h\r\nok\r\nbad"quote\r\n';
        CsvParser.Chunk first = CsvParser.parseChunk(csv, 0, 2, options());

        Test.startTest();
        try {
            CsvParser.parseChunk(csv, first.nextOffset, 2, options());
            Assert.fail('Expected CsvParseException');
        } catch (CsvParser.CsvParseException e) {
            Assert.isTrue(e.getMessage().contains('offset: ' + csv.indexOf('"')), 'Offset indexes the whole input: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrow_WhenMaxRecordsBelowOne() {
        Test.startTest();
        try {
            CsvParser.parseChunk(CSV, 0, 0, options());
            Assert.fail('Expected CsvParseException');
        } catch (CsvParser.CsvParseException e) {
            Assert.isTrue(e.getMessage().contains('at least 1'), 'Message explains the limit');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrow_WhenStartOffsetNegative() {
        Test.startTest();
        try {
            CsvParser.parseChunk(CSV, -1, 1, options());
            Assert.fail('Expected CsvParseException');
        } catch (CsvParser.CsvParseException e) {
            Assert.isTrue(e.getMessage().contains('offset'), 'Message explains the offset');
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
}
