import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/hub.dart';
import 'package:pb_app/remote.dart';
import 'package:pb_app/sms_client.dart';
import 'package:pb_app/ui/messages.dart';

void main() {
  test('a reply echoed with an old time shows once, on the user side', () {
    final old = ChatMsg(body: 'ok', time: DateTime(2026, 1, 1, 9), out: true);
    final sticker = ChatMsg(
      body: 'sticker',
      time: DateTime(2026, 1, 1, 10),
      out: false,
    );
    final reply = ChatMsg(
      body: 'ok',
      time: DateTime(2026, 1, 1, 10, 3),
      out: true,
    );
    final before = {msgKey(old), msgKey(sticker)};
    // Before the echo: the old "ok" does not hide the new one.
    expect(mergeReplies([old, sticker], [(reply, before)]).length, 3);
    // WhatsApp's echo carries the sticker's time and the contact's name.
    final echo = ChatMsg(body: 'ok', time: sticker.time, out: false);
    final merged = mergeReplies([old, sticker, echo], [(reply, before)]);
    expect(merged.length, 3);
    expect(merged.last.out, true);
  });

  final threads = [
    SmsThread({
      'thread': 1,
      'name': 'Mamá',
      'addresses': ['+34600000001'],
      'snippet': 'Llego a las 8',
      'date': 3000,
      'read': false,
    }),
    SmsThread({
      'thread': 2,
      'name': '',
      'addresses': ['+34600000002', '+34600000003'],
      'snippet': 'Vale',
      'date': 1000,
    }),
  ];
  final notifs = [
    PhoneNotif({
      'key': 'w',
      'app': 'WhatsApp',
      'title': 'Lucía',
      'text': 'Hola',
      'time': 2000,
      'chat': true,
      'messages': [
        {'text': 'Hola', 'time': 2000, 'sender': 'Lucía'},
        {'text': '¿Vienes?', 'time': 2100, 'sender': ''},
      ],
    }),
    PhoneNotif({'key': 'g', 'app': 'Gmail', 'title': 'Factura', 'time': 9000}),
  ];

  test(
    'SMS and app chats in one list, newest first; other notifications stay out',
    () {
      final l = Convo.inbox(threads, notifs);
      expect(l.map((c) => c.key), ['sms:1', 'app:w', 'sms:2']);
      expect(l[1].snippet, '¿Vienes?');
      expect(l[2].title, '+34600000002, +34600000003');
      expect(l[2].thread!.group, isTrue);
    },
  );

  test('search matches names and text', () {
    expect(Convo.inbox(threads, notifs, 'llego').map((c) => c.key), ['sms:1']);
    expect(Convo.inbox(threads, notifs, 'LUC').map((c) => c.key), ['app:w']);
    expect(Convo.inbox(threads, notifs, 'nada'), isEmpty);
  });

  test('an SMS message keeps direction, attachments and failure', () {
    final m = ChatMsg.fromSms({
      'id': 'm1',
      'body': '',
      'date': 5,
      'out': true,
      'media': 2,
      'failed': true,
    });
    expect((m.out, m.media, m.failed), (true, 2, true));
  });

  test(
    'hub changes never wipe the open chat (bug: chat vanished while typing)',
    () {
      final hub = _QuietHub();
      final sms = SmsClient(hub)..start('phone');
      sms.onMessage('phone', 'pb.x.sms.threads', {
        'items': [
          {
            'thread': 1,
            'name': 'Mamá',
            'addresses': ['+34600000001'],
            'date': 1,
          },
        ],
      });
      sms.select(1);
      sms.onMessage('phone', 'pb.x.sms.messages', {
        'thread': 1,
        'items': [
          {'id': 'm1', 'body': 'Hola', 'date': 1, 'incoming': true},
        ],
      });
      // The phone was slow once, then the hub changes many times (notifications, battery, media).
      sms.error = 'offline';
      for (var i = 0; i < 5; i++) {
        sms.start('phone');
      }
      expect(sms.threads.map((t) => t.id), [1]);
      expect(sms.messages[1], hasLength(1));
      expect(sms.open, 1);
    },
  );
}

class _QuietHub extends Hub {
  @override
  Future<void> sendMessage(
    String peer,
    String kind,
    Map<String, Object?> body,
  ) async {}
}
