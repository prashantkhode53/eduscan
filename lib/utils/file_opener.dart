import 'dart:io';
import 'package:open_filex/open_filex.dart';
// Re-export so callers that inspect `result.type` / `ResultType` keep those
// symbols in scope by importing only this helper.
export 'package:open_filex/open_filex.dart' show OpenResult, ResultType;

/// Opens a saved file with the OS default application.
///
/// On Android/iOS this delegates to `open_filex` exactly as before (so the
/// existing behaviour — including the [OpenResult] returned to callers that
/// inspect `result.type` — is unchanged).
///
/// `open_filex` has no Windows implementation (its pubspec declares only
/// `android`/`ios`), so on Windows we shell out to Explorer, which opens the
/// file with whatever app is registered for that extension. We synthesise an
/// [OpenResult] so result-checking callers keep working identically.
class FileOpener {
  FileOpener._();

  static Future<OpenResult> open(String path) async {
    if (Platform.isWindows) {
      try {
        // `explorer "<path>"` launches the default handler for the file type.
        // explorer.exe frequently returns a non-zero exit code even on success,
        // so we treat a successful process launch as "done".
        await Process.run('explorer', [path]);
        return OpenResult(type: ResultType.done);
      } catch (e) {
        return OpenResult(type: ResultType.error, message: e.toString());
      }
    }
    return OpenFilex.open(path);
  }
}
