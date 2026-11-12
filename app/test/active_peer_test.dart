import 'package:flutter_test/flutter_test.dart';
import 'package:pb_app/hub.dart';
import 'package:pb_app/src/rust/api/engine.dart' as pb;
import 'package:pb_app/ui/home.dart';

pb.Peer pc(String id, {pb.PeerState state = pb.PeerState.connected}) =>
    pb.Peer(id: id, name: id, addr: '', state: state, trusted: true, detail: '');

void main() {
  test('Home acts on the picked device, and falls back when it is gone', () {
    final hub = Hub()..peers = [pc('win'), pc('deb')];
    expect(mainPeer(hub)?.id, 'win'); // nothing picked: first online
    hub.activePeerId = 'deb';
    expect(mainPeer(hub)?.id, 'deb');
    hub.peers = [pc('win')]; // the picked one was forgotten
    expect(mainPeer(hub)?.id, 'win');
  });
}
