import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Starts Windows' OBS virtual-camera device from the phone-camera window.
/// OBS Studio 28+ must be installed and its local WebSocket server enabled.
class ObsWebcam {
  ObsWebcam._();
  static _ObsConnection? _active;
  static int _nextId = 0;

  static String _hash64(String value) =>
      base64Encode(sha256.convert(utf8.encode(value)).bytes);

  static Future<_ObsConnection> _connect(String password) async {
    final socket = await WebSocket.connect('ws://127.0.0.1:4455')
        .timeout(const Duration(seconds: 8));
    final connection = _ObsConnection(socket);
    try {
      final hello = await connection.next();
      if (hello['op'] != 0) {
        throw const FormatException('OBS WebSocket 5 no está disponible.');
      }
      final auth = (hello['d'] as Map?)?['authentication'];
      final identify = <String, Object>{'rpcVersion': 1};
      if (auth is Map) {
        if (password.isEmpty) {
          throw const FormatException('Introduce la contraseña de OBS WebSocket.');
        }
        final salt = auth['salt'] as String? ?? '';
        final challenge = auth['challenge'] as String? ?? '';
        identify['authentication'] = _hash64(_hash64(password + salt) + challenge);
      }
      socket.add(jsonEncode({'op': 1, 'd': identify}));
      final reply = await connection.next();
      if (reply['op'] != 2) {
        throw const FormatException('OBS rechazó la conexión o su contraseña.');
      }
      return connection;
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> _request(
    _ObsConnection connection, String type,
    [Map<String, Object?> requestData = const {}]
  ) async {
    final requestId = 'alero-${++_nextId}';
    connection.socket.add(jsonEncode({
      'op': 6,
      'd': {'requestType': type, 'requestId': requestId, 'requestData': requestData},
    }));
    while (true) {
      final reply = await connection.next();
      if (reply['op'] != 7) continue;
      final data = reply['d'];
      if (data is! Map || data['requestId'] != requestId) continue;
      final status = data['requestStatus'];
      if (status is! Map || status['result'] != true) {
        throw FormatException(
          'OBS rechazó $type: ${status is Map ? (status['comment'] ?? status['code']).toString() : 'desconocido'}',
        );
      }
      return Map<String, dynamic>.from(data['responseData'] as Map? ?? {});
    }
  }

  /// The scrcpy camera window is the OBS Window Capture scene source; the
  /// virtual camera is then a genuine Windows video input.
  static Future<void> start({
    required String windowTitle,
    required String password,
  }) async {
    await stop(silent: true);
    final connection = await _connect(password);
    try {
      const scene = 'Alero Webcam';
      const source = 'Alero - cámara del teléfono';
      final scenes = await _request(connection, 'GetSceneList');
      final exists = (scenes['scenes'] as List? ?? [])
          .whereType<Map>().any((item) => item['sceneName'] == scene);
      if (!exists) await _request(connection, 'CreateScene', {'sceneName': scene});

      final inputs = await _request(connection, 'GetInputList');
      final sourceExists = (inputs['inputs'] as List? ?? [])
          .whereType<Map>().any((item) => item['inputName'] == source);
      final capture = <String, Object?>{
        'window': '$windowTitle:SDL_app:scrcpy.exe',
        'capture_method': 'auto',
        'cursor': false,
      };
      if (!sourceExists) {
        await _request(connection, 'CreateInput', {
          'sceneName': scene,
          'inputName': source,
          'inputKind': 'window_capture',
          'inputSettings': capture,
          'sceneItemEnabled': true,
        });
      } else {
        await _request(connection, 'SetInputSettings', {
          'inputName': source,
          'inputSettings': capture,
          'overlay': true,
        });
        final items = await _request(connection, 'GetSceneItemList',
            {'sceneName': scene});
        if (!(items['sceneItems'] as List? ?? []).whereType<Map>()
            .any((item) => item['sourceName'] == source)) {
          await _request(connection, 'CreateSceneItem', {
            'sceneName': scene, 'sourceName': source,
          });
        }
      }
      await _request(connection, 'SetCurrentProgramScene', {'sceneName': scene});
      final status = await _request(connection, 'GetVirtualCamStatus');
      if (status['outputActive'] != true) {
        await _request(connection, 'StartVirtualCam');
      }
      _active = connection;
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  static Future<void> stop({bool silent = false}) async {
    final connection = _active;
    _active = null;
    if (connection == null) return;
    try {
      final status = await _request(connection, 'GetVirtualCamStatus');
      if (status['outputActive'] == true) {
        await _request(connection, 'StopVirtualCam');
      }
    } catch (_) {
      if (!silent) rethrow;
    } finally {
      await connection.close();
    }
  }
}

class _ObsConnection {
  _ObsConnection(this.socket) : messages = StreamIterator<dynamic>(socket);
  final WebSocket socket;
  final StreamIterator<dynamic> messages;

  Future<Map<String, dynamic>> next() async {
    final ready = await messages.moveNext().timeout(const Duration(seconds: 8));
    if (!ready) throw const FormatException('OBS cerró la conexión.');
    return jsonDecode(messages.current as String) as Map<String, dynamic>;
  }

  Future<void> close() async {
    await messages.cancel();
    await socket.close();
  }
}
