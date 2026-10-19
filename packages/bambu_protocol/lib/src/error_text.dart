/// Sentence-table lookups for HMS and print_error codes.
///
/// Data comes from [error_text_tables.dart] (generated from Bambu's own
/// error feed - the same source BambuHelper ships in include/error_tables).
/// Lookups are plain map hits on the lowercase-hex keys the generator
/// emits, so there is no binary search to keep in sync.
library;

import 'models.dart';
import 'error_text_tables.dart';

/// Feed version stamp, e.g. `202608122107` (UTC yyyymmddhhmm).
String get errorTableVersion => kErrorTableVersion;

/// Human sentence for an HMS code, or null when the feed doesn't know it.
String? hmsDescription(HmsEntry entry) => kHmsErrorText[entry.hexKey];

/// Human sentence for a `print.print_error` code, or null when unknown.
String? printErrorDescription(int printError) =>
    kPrintErrorText[printError.toRadixString(16).padLeft(8, '0')];

/// Bambu wiki page path for an HMS code (e.g.
/// `a1/troubleshooting/hmscode/0300_0100_0001_0005`), null when none.
/// Prefix with `https://wiki.bambulab.com/en/` for the full URL.
String? hmsWikiPath(HmsEntry entry) => kHmsWikiPath[entry.hexKey];
