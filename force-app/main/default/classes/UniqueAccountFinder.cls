public without sharing class UniqueAccountFinder {

    private class Result {
        Account account;
        Boolean found_unique_account;
        Boolean found_no_account;
        Boolean found_multiple_accounts;
        Boolean no_input_values;
        Boolean unexpected_record_type;
        Boolean bad_unique_id;
        Boolean bad_key_values;

        // *** If a Facility Name is the only thing that changed, clear the list of changed fields since we don't want to warn about it

        Map<String, String> matched_key_values_by_field  = new Map<String, String>{};
        Map<String, String> matched_data_values_by_field = new Map<String, String>{};

        Map<String, Map<String, String>> unmatched_key_values_by_field  = new Map<String, Map<String, String>>{}; // Field_Name => {'account' => <account value>, 'input' => <input value>}
        Map<String, Map<String, String>> unmatched_data_values_by_field = new Map<String, Map<String, String>>{};
    }

    private static Map<String, Id> record_type_ids_by_name = new Map<String, Id>{
        'Provider'             => Utilities.record_type_id('Account', 'Provider'),
        'Organization'         => Utilities.record_type_id('Account', 'Organization'),
        'Participant_Facility' => Utilities.record_type_id('Account', 'Participant_Facility')
    };

    // These "Key_Field" fields are API Names for the fields identified separately as important for each record type.
    private static Map<String, String[]> key_fields_by_record_type = new Map<String, String[]>{
        'Provider'             => new String[]{'NPI__c'},
        'Organization'         => new String[]{'Group_Type_2_NPI__c', 'HealthCloudGA__TaxId__c', 'ShippingStreet', 'ShippingCity', 'ShippingState', 'ShippingPostalCode'},
        'Participant_Facility' => new String[]{'Group_Type_2_NPI__c', 'HealthCloudGA__TaxId__c', 'ShippingStreet', 'ShippingCity', 'ShippingState', 'ShippingPostalCode'}
    };

    // private static Map<String, String[]> locked_data_fields_by_record_type = new Map<String, String[]>{
    //     'Provider'             => new String[]{},
    //     'Organization'         => new String[]{},
    //     'Participant_Facility' => new String[]{}
    // };

    private static Map<String, String[]> data_fields_by_record_type = new Map<String, String[]>{
        'Provider'             => new String[]{},
        'Organization'         => new String[]{},
        'Participant_Facility' => new String[]{}
    };

    private static String innovage_unique_id_field = 'InnovAge_Unique_ID__c';
    private static String record_type;

    private static Result unique_account(Map<String, String> inputs) {
        // "inputs" is a Map of Account field API names pointing to values for those fields that will hopefully be found in the database (ie the values from a single row of a Prover Directory roster intake sheet).
        // There should be a key of "record type" that has the DeveloperName of the desired record type for the account.

        /* General logic
            Search for accounts that match either the InnovAge Unique ID (if provided) OR a list of other fields (for Individual Providers, the "list" of fields is just NPI)

            If zero records are found, flag as "found_no_account".
            Also, check if the InnovAge Unique ID was provided. If it was, that's a problem because it SHOULD always match a record - flag a "bad_unique_id".

            If multiple records are found, that's a problem that should be reviewed - flag with "found_multiple_accounts".

            If only one record is found, confirm both the InnovAge Unique ID and other key fields all match.
            If the InnovAge Unique ID doesn't match, flag a "bad_unique_id".
            If any of the key fields don't match, flag with "bad_key_values". Matched and unmatched values can be found in the "matched_key_values_by_field" and "unmatched_key_values_by_field" properties.
            If there are no problems, flag with "found_unique_account" and put the account in the "account" property.
            Also, identify all the non-key (aka "data") fields that match and don't match between the input and account values because we want to warn the user about those changed values.
        */


        Result result = new Result();

        record_type = inputs.get('record type');

        if (!record_type_ids_by_name.containsKey(record_type)) {
            result.unexpected_record_type = true;
            return result;
        }

        sanitize_inputs(inputs); // Some inputs might need to be cleaned up
        String innovage_unique_id = inputs.get(innovage_unique_id_field);

        // We don't want to compare Account records against values that weren't provided in the intake sheet, so we filter down the key fields to only those that have input values
        String[] key_fields_with_input_values = fields_with_input_values(key_fields_by_record_type.get(record_type), inputs); 

        if (String.isBlank(innovage_unique_id) && key_fields_with_input_values.isEmpty()) {
            result.no_input_values  = true;
            result.found_no_account = true;
        } else {
            Account[] accounts = accounts_with_matching_values(inputs, key_fields_with_input_values);

            if (accounts.isEmpty())  { // Didn't find any accounts
                result.found_no_account = true;
                if (String.isNotBlank(innovage_unique_id)) {result.bad_unique_id = true;}
            }
            else if (accounts.size() > 1) {result.found_multiple_accounts = true;} // Found more than one
            else { // Found exactly one account

                Account account = accounts[0];

                find_input_matches(key_fields_with_input_values, inputs, account, result.matched_key_values_by_field, result.unmatched_key_values_by_field);
                Boolean key_fields_match      = result.unmatched_key_values_by_field.isEmpty();
                Boolean innovage_unique_id_ok = String.isBlank(innovage_unique_id) || innovage_unique_id == (String)account.get(innovage_unique_id_field);

                if      (!key_fields_match)      {result.bad_key_values = true;}
                else if (!innovage_unique_id_ok) {result.bad_unique_id  = true;}
                else { // key fields match and innovage unique id matches
                    result.found_unique_account = true;
                    result.account              = account;

                    find_input_matches(data_fields_by_record_type.get(record_type), inputs, account, result.matched_data_values_by_field, result.unmatched_data_values_by_field);
                }
            }
        }

        return result;
    }

    private static void sanitize_inputs(Map<String, String> inputs) {
        // There is a concern that the input provided for the InnovAge Unique ID will be wrong or malformed. If so, clear it out so it doesn't filter out any records.
        clear_bad_innovage_unique_id(inputs);
    }
    private static void clear_bad_innovage_unique_id(Map<String, String> inputs) {
        if (inputs.containsKey(innovage_unique_id_field)) {
            String unique_id = inputs.get(innovage_unique_id_field);
            if (String.isNotBlank(unique_id) && !valid_id(unique_id)) {inputs.put(innovage_unique_id_field, null);}
        }
    }
    private static Boolean valid_id(String input) {
        String regex = '^(?:MF|O|P|PG)\\d{9}[a-zA-Z0-9]{3}$'; // MF/O/P/PG + 9 numbers + 3 alphanumeric

        Pattern the_pattern = pattern.compile(regex);
        Matcher matcher     = the_pattern.matcher(input);

        return matcher.matches();
    }

    private static String[] fields_with_input_values(String[] comparison_fields, Map<String, String> inputs) {
        String[] fields_with_input_values = new String[]{};

        for (String field : comparison_fields) {
            String input_value = inputs.get(field);
            if (String.isNotBlank(input_value)) {fields_with_input_values.add(field);}
        }

        return fields_with_input_values;
    }

    private static Account[] accounts_with_matching_values(Map<String, String> inputs, String[] key_fields_with_input_values) {
        Set<String> fields_to_query = new Set<String>(key_fields_with_input_values);
        fields_to_query.addAll(data_fields_by_record_type.get(record_type));
        String fields_query_string = String.join(fields_to_query, ', ');

        String complete_field_filter_string = complete_field_filter_string(inputs, key_fields_with_input_values);

        Id record_type_id = record_type_ids_by_name.get(record_type);

        String query_string = 'SELECT Id, ' + fields_query_string + ' ' +
                                'FROM Account ' +
                                'WHERE RecordTypeId = :record_type_id ' + complete_field_filter_string;

        return Database.query(query_string, AccessLevel.SYSTEM_MODE);
    }
    private static String complete_field_filter_string(Map<String, String> inputs, String[] key_fields_with_input_values) {
        /*  Filter by the InnovAge Unique ID  -OR-  all the other key fields together.
            Output example:
                AND (
                    InnovAge_Unique_ID__c = <Unique ID Input Value>
                    OR (
                        Key_Field_1__c = <Key Field 1 Input Value>
                        AND
                        Key_Field_2__c = <Key Field 2 Input Value>
                    )
                )
        */

        String[] filter_strings = new String[]{};

        String innovage_unique_id       = inputs.get(innovage_unique_id_field);
        String unique_id_filter_string  = String.isNotBlank(innovage_unique_id) ? innovage_unique_id_field + ' = ' + innovage_unique_id : null;
        String key_fields_filter_string = key_fields_filter_string(key_fields_with_input_values, inputs);

        if (String.isNotBlank(unique_id_filter_string))  {filter_strings.add(unique_id_filter_string);}
        if (String.isNotBlank(key_fields_filter_string)) {filter_strings.add(key_fields_filter_string);}

        return !filter_strings.isEmpty() ? 'AND (' + String.join(filter_strings, ' OR ') + ')' : '';
    }
    private static String key_fields_filter_string(String[] key_fields_with_input_values, Map<String, String> inputs) {
        if (key_fields_with_input_values.isEmpty()) {return null;}

        String key_fields_filter_string;

        String[] field_comparisons = new String[]{};
        for (String field : key_fields_with_input_values) {
            String input_value = inputs.get(field);
            field_comparisons.add(field + ' = ' + input_value);
        }

        return ' (' + String.join(field_comparisons, ' AND ') + ') ';
    }

    private static void find_input_matches(String[] comparison_fields, Map<String, String> inputs, Account account, Map<String, String> matched_values_by_field, Map<String, Map<String, String>> unmatched_values_by_field) {
        for (String field : comparison_fields) {
            String input_value   = inputs.get(field);
            String account_value = (String)account.get(field);

            if (input_value == account_value) {matched_values_by_field.put(field, account_value);}
            else                              {unmatched_values_by_field.put(field, new Map<String, String>{'input' => input_value, 'account' => account_value});}
        }
    }


        // private static Account[] find_unique_account(Account[] accounts, String[] key_fields, Integer key_field_index, Map<String, String> inputs) {
        //     /*  A recursive function that attempts to reduce an initial List of Account records down to a single record.

        //         Plain explanation
        //         This logic takes a list of accounts and filters them down by comparing their values for each identified key field, completely ignoring a key field if no value was provided for it in the intake sheet.
        //         It filters the list by each key field, one-by-one and ends when it gets down to a single record, filters out all possibilities, or runs out of key fields for comparison, in which case, we don't have uniqueness.

        //         Technical algorithm
        //             Check how many records are present and confirm there is a key to filter against.

        //             If there are multiple records, filter them against the key field's value and send the remaining accounts back into the logic.
        //             If there is only zero or one record, or we've run out of key fields to filter with, return the accounts.
        //     */

        //     Boolean has_key_field_for_filtering = key_field_index < key_fields.size();

        //     if (accounts.size() > 1 && has_key_field_for_filtering) {
        //         String    filter_field      = key_fields.get(key_field_index);
        //         Account[] filtered_accounts = filtered_accounts(accounts, filter_field, inputs);

        //         return find_unique_account(filtered_accounts, key_fields, key_field_index++, inputs);
        //     }

        //     return accounts;
        // }
        //     private static Account[] filtered_accounts(Account[] accounts, String filter_field, Map<String, String> inputs) {
        //         Account[] filtered_accounts = new Account[]{};

        //         String target_value = inputs.get(filter_field);
        //         for (Account account : accounts) {
        //             String value_of_field_in_record = (String)account.get(filter_field);
        //             if (value_of_field_in_record == target_value) {filtered_accounts.add(account);}
        //         }

        //         return filtered_accounts;
        //     }
}
