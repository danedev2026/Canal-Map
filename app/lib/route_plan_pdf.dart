import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// One facility passed on the route, for the PDF plan.
class PlanFacility {
  PlanFacility(this.label, this.name, this.miles, this.day);
  final String label;
  final String name;
  final double miles;
  final int day;
}

const _green = PdfColor.fromInt(0xFF16302B);
const _gold = PdfColor.fromInt(0xFFD9A62A);
const _mute = PdfColor.fromInt(0xFF667770);
const _soft = PdfColor.fromInt(0xFFF4F7F6);
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _eta(int mins) {
  final h = mins ~/ 60, m = mins % 60;
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}

/// Build a branded route-plan PDF and hand it to the system share/save sheet.
/// £0: everything is generated on-device, no service.
Future<void> sharePlanPdf({
  required double miles,
  required int locks,
  required int etaMinutes,
  required int hoursPerDay,
  required int days,
  required List<String> waterways,
  required List<PlanFacility> facilities,
  Uint8List? routeImage,
}) async {
  final doc = pw.Document();
  final now = DateTime.now();
  final today = '${now.day} ${_months[now.month - 1]} ${now.year}';

  final rows = <pw.Widget>[];
  var curDay = 0;
  for (final f in facilities) {
    if (f.day != curDay) {
      curDay = f.day;
      rows.add(pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(top: 6, bottom: 2),
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        color: _green,
        child: pw.Text('Day $curDay',
            style: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 11)),
      ));
    }
    rows.add(pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2.5, horizontal: 4),
      child: pw.Row(children: [
        pw.SizedBox(width: 52, child: pw.Text('${f.miles.toStringAsFixed(1)} mi',
            style: const pw.TextStyle(color: _mute, fontSize: 10))),
        pw.SizedBox(width: 96, child: pw.Text(f.label, style: const pw.TextStyle(fontSize: 10))),
        pw.Expanded(child: pw.Text(f.name, style: const pw.TextStyle(fontSize: 10))),
      ]),
    ));
  }
  if (rows.isEmpty) {
    rows.add(pw.Text('No mapped facilities within 300 m of this route.',
        style: const pw.TextStyle(color: _mute, fontSize: 10)));
  }

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (ctx) => [
      // Note: the built-in PDF font is Latin-1 only, so we avoid emoji / arrows
      // / em-dashes here (a small gold square stands in for the brand mark).
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
        pw.Container(width: 16, height: 16,
            decoration: const pw.BoxDecoration(color: _gold, shape: pw.BoxShape.circle)),
        pw.SizedBox(width: 8),
        pw.Text('Canal Map ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 18, color: _green)),
        pw.Text('UK WATERWAYS · route plan', style: const pw.TextStyle(color: _mute, fontSize: 11)),
      ]),
      pw.Divider(color: _green, thickness: 2),
      pw.SizedBox(height: 6),
      pw.Text('Produced $today by Canal Map: UK Waterways. Distances, lock counts '
          'and times are estimates - always check current notices and conditions '
          'before setting off.',
          style: const pw.TextStyle(color: _mute, fontSize: 10)),
      pw.SizedBox(height: 12),
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(12),
        decoration: const pw.BoxDecoration(
          color: _soft,
          border: pw.Border(left: pw.BorderSide(color: _green, width: 4)),
        ),
        child: pw.Text(
          '${miles.toStringAsFixed(1)} miles · $locks locks · about ${_eta(etaMinutes)} '
          'cruising - roughly $days day${days == 1 ? '' : 's'} at $hoursPerDay hours/day.',
          style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
        ),
      ),
      if (routeImage != null) ...[
        pw.SizedBox(height: 14),
        pw.ClipRRect(
          horizontalRadius: 6, verticalRadius: 6,
          child: pw.Image(pw.MemoryImage(routeImage), fit: pw.BoxFit.contain),
        ),
      ],
      pw.SizedBox(height: 16),
      pw.Text('Waterways', style: pw.TextStyle(color: _green, fontWeight: pw.FontWeight.bold, fontSize: 13)),
      pw.SizedBox(height: 4),
      pw.Text(waterways.isEmpty ? '-' : waterways.join('  >  '),
          style: const pw.TextStyle(fontSize: 11)),
      pw.SizedBox(height: 16),
      pw.Text('Along the way', style: pw.TextStyle(color: _green, fontWeight: pw.FontWeight.bold, fontSize: 13)),
      pw.SizedBox(height: 4),
      ...rows,
      pw.SizedBox(height: 18),
      pw.Divider(color: PdfColors.grey300),
      pw.Text('Contains data from OpenStreetMap contributors (ODbL), the Canal & '
          'River Trust and the Environment Agency, under their respective open '
          'licences. Generated with Canal Map: UK Waterways.',
          style: const pw.TextStyle(color: _mute, fontSize: 9)),
    ],
  ));

  final bytes = await doc.save();
  final stamp = now.toIso8601String().split('T').first;
  await Printing.sharePdf(bytes: bytes, filename: 'canal-map-route-$stamp.pdf');
}
