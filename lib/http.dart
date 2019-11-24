// Copyright 2019 dartssh developers
// Use of this source code is governed by a MIT-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:dartssh/client.dart';
import 'package:dartssh/serializable.dart';
import 'package:dartssh/transport.dart';

typedef HttpClientFactory = http.Client Function();

/// Asynchronous HTTP request
class HttpRequest {
  String url, method, data;
  Completer<HttpResponse> completer = Completer<HttpResponse>();
  HttpRequest(this.url, this.method, this.data);
}

/// HTTP response integrating [io.HttpClient] and [html.HttpRequest].
class HttpResponse {
  int status;
  String text;
  HttpResponse(this.status, [this.text]);
}

/// HTTP client integrating [io.HttpClient] and [html.HttpRequest].
abstract class HttpClient {
  int numOutstanding = 0;
  StringCallback debugPrint;
  HttpClient([this.debugPrint]);

  Future<HttpResponse> request(String url, {String method, String data});
}

/// Shim [HttpClient] for testing
class TestHttpClient extends HttpClient {
  Queue<HttpRequest> requests = Queue<HttpRequest>();

  @override
  Future<HttpResponse> request(String url, {String method, String data}) {
    HttpRequest httpRequest = HttpRequest(url, method, data);
    requests.add(httpRequest);
    return httpRequest.completer.future;
  }
}

/// package:http based implementation of [HttpClient].
class HttpClientImpl extends HttpClient {
  HttpClientFactory clientFactory;
  HttpClientImpl(
      {this.clientFactory, StringCallback debugPrint, StringFilter userAgent})
      : super(debugPrint) {
    clientFactory ??= () => UserAgentBaseClient(
        userAgent == null ? null : userAgent('HttpClientImpl'), http.Client());
  }

  @override
  Future<HttpResponse> request(String url, {String method, String data}) async {
    numOutstanding++;
    if (debugPrint != null) debugPrint('HTTP Request: $url');

    http.Client client = clientFactory();
    var uriResponse;
    switch (method) {
      case 'POST':
        uriResponse = await client.post(url, body: data);
        break;

      default:
        uriResponse = await client.get(url);
        break;
    }

    HttpResponse ret = HttpResponse(uriResponse.statusCode, uriResponse.body);
    if (debugPrint != null) {
      debugPrint('HTTP Response=${ret.status}: ${ret.text}');
    }
    numOutstanding--;
    return ret;
  }

  void requestWithIncrementalHandler(String url,
      {String method, String data}) async {
    var request = http.Request(method ?? 'GET', Uri.parse(url));
    var response = await request.send();
    var lineStream =
        response.stream.transform(Utf8Decoder()).transform(LineSplitter());

    /// https://github.com/llamadonica/dart-json-stream-parser/tree/master/test
    await for (String line in lineStream) {
      print(line);
    }
  }
}

class UserAgentBaseClient extends http.BaseClient {
  final String userAgent;
  final http.Client inner;
  UserAgentBaseClient(this.userAgent, this.inner);

  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (userAgent != null) {
      request.headers['user-agent'] = userAgent;
    }
    return inner.send(request);
  }
}

class SSHTunneledBaseClient extends http.BaseClient {
  final String userAgent;
  final SSHClient client;
  SSHTunneledBaseClient(this.client, {this.userAgent});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (userAgent != null) {
      request.headers['user-agent'] = userAgent;
    }

    Completer<String> connectCompleter = Completer<String>();
    SSHTunneledSocketImpl socket = SSHTunneledSocketImpl.fromClient(client);
    socket.connect(request.url, () => connectCompleter.complete(null),
        (error) => connectCompleter.complete('$error'));
    String connectError = await connectCompleter.future;
    if (connectError != null) throw FormatException(connectError);

    String headers;
    Completer<String> readHeadersCompleter = Completer<String>();
    QueueBuffer buffer = QueueBuffer(Uint8List(0));
    socket.handleDone(() => readHeadersCompleter.complete('done'));
    socket.handleError((error) => readHeadersCompleter.complete('$error'));
    socket.listen((Uint8List m) {
      buffer.add(m);
      if (headers == null) {
        int headersEnd = searchUint8List(
            buffer.data, Uint8List.fromList('\r\n\r\n'.codeUnits));
        if (headersEnd != -1) {
          headers = utf8.decode(viewUint8List(buffer.data, 0, headersEnd));
          buffer.flush(headersEnd + 4);
          readHeadersCompleter.complete(null);
        }
      }
    });

    Uint8List body;
    if (request.method == 'POST') {
      body = await request.finalize().toBytes();
      request.headers['Content-Length'] = '${body.length}';
    }
    socket.send('${request.method} /${request.url.path} HTTP/1.1\r\n' +
        request.headers.entries
            .map((header) => '${header.key}: ${header.value}')
            .join('\r\n') +
        '\r\n\r\n');
    if (request.method == 'POST') socket.sendRaw(body);

    await readHeadersCompleter.future;
    print('got headers $headers');

    return http.StreamedResponse(
      Stream.empty(),
      200,
      contentLength: 0,
      request: request,
      headers: {'Content-Length': '0'},
      reasonPhrase: 'OK',
    );
  }
}