import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// QR code drawn from modules. Always dark on white with a quiet zone, whatever the theme, so cameras read it.
class QrView extends StatelessWidget {
  const QrView(this.data, {super.key, this.size = 200, required this.label});
  final String data, label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final img = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium));
    return Semantics(
      image: true,
      label: label,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.06),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: CustomPaint(painter: _Qr(img)),
      ),
    );
  }
}

class _Qr extends CustomPainter {
  _Qr(this.img);
  final QrImage img;

  @override
  void paint(Canvas canvas, Size s) {
    final n = img.moduleCount;
    final m = s.shortestSide / n;
    final p = Paint()..color = const Color(0xFF111111);
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (img.isDark(r, c)) canvas.drawRect(Rect.fromLTWH(c * m, r * m, m + 0.5, m + 0.5), p);
      }
    }
  }

  @override
  bool shouldRepaint(_Qr o) => o.img != img;
}
