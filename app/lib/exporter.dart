import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// One place for turning generated text (GPX / CSV) into a file the user can
/// actually keep. Offers a clear choice:
///   • Save to device — the native "Save to…" dialog, so the file lands in
///     Files / Downloads where the user can find and reopen it. No storage
///     permission needed (uses the system document picker).
///   • Share — the usual share sheet (email, messaging, other apps).
class Exporter {
  /// Presents the chooser, writes [content] to a temp file named [filename],
  /// then either saves it to a user-picked location or shares it.
  static Future<void> saveOrShare(
    BuildContext context, {
    required String filename,
    required String content,
    required String mimeType,
    required String shareText,
    String? shareSubject,
  }) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Save or share'),
              subtitle: Text('Keep the file on your phone, or send it on'),
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Save to device'),
              subtitle: const Text('Choose where — appears in Files / Downloads'),
              onTap: () => Navigator.pop(c, 'save'),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Share'),
              subtitle: const Text('Send by email, messaging or to another app'),
              onTap: () => Navigator.pop(c, 'share'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/$filename';
    await File(path).writeAsString(content, flush: true);

    if (choice == 'save') {
      final saved = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          sourceFilePath: path,
          fileName: filename,
          mimeTypesFilter: [mimeType],
        ),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(saved == null
              ? 'Save cancelled'
              : 'Saved to your device as $filename'),
        ));
      }
    } else {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(path, mimeType: mimeType)],
        subject: shareSubject,
        text: shareText,
      ));
    }
  }
}
