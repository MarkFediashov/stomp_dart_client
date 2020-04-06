import 'dart:async';

import 'package:stomp_dart_client/stomp_config.dart';
import 'package:stomp_dart_client/stomp_handler.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

void main() {
  group('StompHandler', () {
    StompConfig config;
    StompHandler handler;
    StreamChannel streamChannel;
    int port;

    setUpAll(() async {
      // Basic STOMP Server
      streamChannel = spawnHybridCode(r'''
        import 'dart:io';
        import 'dart:async';
        import 'package:web_socket_channel/io.dart';
        import 'package:stomp_dart_client/stomp_parser.dart';
        import 'package:stream_channel/stream_channel.dart';
        
        hybridMain(StreamChannel channel) async {
          HttpServer server = await HttpServer.bind("localhost", 0);
          server.transform(WebSocketTransformer()).listen((webSocket) {
            var webSocketChannel = IOWebSocketChannel(webSocket);
            var parser = StompParser((frame) {
              if (frame.command == 'CONNECT') {
                webSocketChannel.sink.add("CONNECTED\nversion:1.2\n\n\x00");
              } else if (frame.command == 'DISCONNECT') {
                webSocketChannel.sink
                    .add("RECEIPT\nreceipt-id:${frame.headers['receipt']}\n\n\x00");
              } else if (frame.command == 'SUBSCRIBE') {
                webSocketChannel.sink.add(
                    "MESSAGE\nsubscription:${frame.headers['id']}\nmessage-id:123\ndestination:/foo\n\nThis is the message body\x00");
              } else if (frame.command == 'UNSUBSCRIBE' ||
                  frame.command == 'SEND') {
                if (frame.headers?.containsKey('receipt') ?? false) {
                  webSocketChannel.sink.add(
                      "RECEIPT\nreceipt-id:${frame.headers['receipt']}\n\n${frame.body}\x00");

                  if (frame.command == 'UNSUBSCRIBE') {
                    Timer(Duration(milliseconds: 500), () {
                      webSocketChannel.sink.add(
                          "MESSAGE\nsubscription:${frame.headers['id']}\nmessage-id:123\ndestination:/foo\n\nThis is the message body\x00");
                    });
                  }
                }
              } else if (frame.command == 'ACK' || frame.command == 'NACK') {
                  webSocketChannel.sink.add(
                      "RECEIPT\nreceipt-id:${frame.headers['receipt']}\n\n${frame.headers['id']}\x00");
              }
            });
            webSocketChannel.stream.listen((request) {
              parser.parseData(request);
            });
          });

          channel.sink.add(server.port);
        }
      ''', stayAlive: true);

      port = await streamChannel.stream.first;
      config = StompConfig(
        url: 'ws://localhost:$port',
      );
    });

    tearDown(() async {
      handler?.dispose();
    });

    test('connects correctly', () async {
      dynamic onConnect = expectAsync2((_, frame) {
        expect(frame.command, 'CONNECTED');
        expect(frame.headers.length, 1);
        expect(frame.headers['version'], '1.2');
        expect(frame.body, isEmpty);
        handler.dispose();
      });

      handler = StompHandler(config: config.copyWith(onConnect: onConnect));

      handler.start();
    });

    test('disconnects correctly', () async {
      dynamic onWebSocketDone = expectAsync0(() {}, count: 1);

      dynamic onDisconnect = expectAsync1((frame) {
        expect(handler.connected, isFalse);
        expect(frame.command, 'RECEIPT');
        expect(frame.headers.length, 1);
        expect(frame.headers['receipt-id'], 'disconnect-0');
      }, count: 1);

      dynamic onConnect = expectAsync2((_, frame) {
        Timer(Duration(milliseconds: 500), () {
          handler.dispose();
        });
      }, count: 1);

      dynamic onError = expectAsync1((_) {}, count: 0);

      handler = StompHandler(
          config: config.copyWith(
              onConnect: onConnect,
              onDisconnect: onDisconnect,
              onWebSocketDone: onWebSocketDone,
              onStompError: onError,
              onWebSocketError: onError));

      handler.start();
    });

    test('subscribes correctly', () {
      dynamic onSubscriptionFrame = expectAsync1((frame) {
        expect(frame.command, 'MESSAGE');
        expect(frame.headers.length, 3);
        expect(frame.headers['subscription'], 'sub-0');
        expect(frame.headers['destination'], '/foo');
        expect(frame.body, 'This is the message body');
      });

      // We need this async waiter to make sure we actually wait until the
      // connection is closed to not affect other tests
      dynamic onDisconnect = expectAsync1((frame) {}, count: 1);

      handler = StompHandler(
          config: config.copyWith(
              onConnect: (_, frame) {
                handler.subscribe(
                    destination: '/foo',
                    callback: onSubscriptionFrame,
                    headers: {"id": "sub-0"});
                Timer(Duration(milliseconds: 500), () {
                  handler.dispose();
                });
              },
              onDisconnect: onDisconnect));

      handler.start();
    });

    test('unsubscribes correctly', () {
      dynamic onSubscriptionFrame = expectAsync1((frame) {
        expect(frame.command, 'MESSAGE');
        expect(frame.headers.length, 3);
        expect(frame.headers['subscription'], 'sub-0');
        expect(frame.headers['destination'], '/foo');
        expect(frame.body, 'This is the message body');
      }, count: 1);

      dynamic onReceiptFrame = expectAsync1((frame) {
        expect(frame.command, 'RECEIPT');
        expect(frame.headers['receipt-id'], 'unsub-0');
      });

      // We need this async waiter to make sure we actually wait until the
      // connection is closed
      dynamic onDisconnect = expectAsync1((frame) {}, count: 1);

      handler = StompHandler(
          config: config.copyWith(
              onConnect: (_, frame) {
                var unsubscribe = handler.subscribe(
                    destination: '/foo',
                    callback: onSubscriptionFrame,
                    headers: {"id": "sub-0"});
                Timer(Duration(milliseconds: 500), () {
                  unsubscribe(unsubscribeHeaders: {"receipt": "unsub-0"});
                  // We wait an additional second because the server will send
                  // another frame for this subscription and we can make sure that
                  // the subscription on the client side was actually canceled
                  // immediatly
                  Timer(Duration(milliseconds: 1000), () {
                    handler.dispose();
                  });
                });
              },
              onDisconnect: onDisconnect));

      handler.watchForReceipt('unsub-0', onReceiptFrame);

      handler.start();
    });

    test('sends message correctly', () {
      dynamic onReceiptFrame = expectAsync1((frame) {
        expect(frame.command, 'RECEIPT');
        expect(frame.headers['receipt-id'], 'send-0');
        expect(frame.body, 'This is a body');
        handler.dispose();
      });

      // We need this async waiter to make sure we actually wait until the
      // connection is closed
      dynamic onDisconnect = expectAsync1((frame) {}, count: 1);

      handler = StompHandler(
          config: config.copyWith(
              onConnect: (_, frame) {
                handler.send(
                    destination: '/foo/bar',
                    body: 'This is a body',
                    headers: {"receipt": "send-0"});
              },
              onDisconnect: onDisconnect));

      handler.watchForReceipt('send-0', onReceiptFrame);

      handler.start();
    });

    test('acks message correctly', () {
      dynamic onReceiptFrame = expectAsync1((frame) {
        expect(frame.command, 'RECEIPT');
        expect(frame.headers['receipt-id'], 'send-0');
        expect(frame.body, 'message-0');
        handler.dispose();
      });

      // We need this async waiter to make sure we actually wait until the
      // connection is closed
      dynamic onDisconnect = expectAsync1((frame) {}, count: 1);

      handler = StompHandler(
          config: config.copyWith(
              onConnect: (_, frame) {
                handler.ack(
                    id: "message-0",
                    headers: {"receipt": "send-0"});
              },
              onDisconnect: onDisconnect));

      handler.watchForReceipt('send-0', onReceiptFrame);

      handler.start();
    });

    test('nacks message correctly', () {
      dynamic onReceiptFrame = expectAsync1((frame) {
        expect(frame.command, 'RECEIPT');
        expect(frame.headers['receipt-id'], 'send-0');
        expect(frame.body, 'message-0');
        handler.dispose();
      });

      // We need this async waiter to make sure we actually wait until the
      // connection is closed
      dynamic onDisconnect = expectAsync1((frame) {}, count: 1);

      handler = StompHandler(
          config: config.copyWith(
              onConnect: (_, frame) {
                handler.nack(
                    id: "message-0",
                    headers: {"receipt": "send-0"});
              },
              onDisconnect: onDisconnect));

      handler.watchForReceipt('send-0', onReceiptFrame);

      handler.start();
    });

  });
}
