import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

bool showRawPayload = false;

void main() {
  runApp(const C6ToolsApp());
}

class C6ToolsApp extends StatelessWidget {
  const C6ToolsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'C6Tools',
      theme: ThemeData.dark(useMaterial3: true),
      home: const DashboardScreen(),
    );
  }
}

enum DeviceStatus { connected, stale, disconnected }

class DeviceModel {
  final String portName;
  final DateTime createdAt = DateTime.now();

  DeviceStatus status = DeviceStatus.disconnected;
  DateTime? lastRx;
  bool isOpen = false;
  int rxBytes = 0;
  List<String> lines = [];

  SerialPort? port;
  SerialPortReader? reader;
  StreamSubscription<Uint8List>? subscription;
  String _buffer = '';

  DeviceModel(this.portName);

  void updateLastRx() {
    lastRx = DateTime.now();
  }

  void openPort() {
    if (isOpen) return;
    try {
      port = SerialPort(portName);
      if (port!.openReadWrite()) {
        isOpen = true;

        // Not: Bazı cihazlar baud rate'i umursamaz (USB-CDC/JTAG).
        // Yine de seri UART kullanıyorsan burada set edebilirsin.
        // final cfg = port!.config;
        // cfg.baudRate = 115200;
        // port!.config = cfg;

        reader = SerialPortReader(port!);
        subscription = reader!.stream.listen((data) {
          rxBytes += data.length;
          updateLastRx();
          _processData(data);
        });

        updateLastRx();
      }
    } catch (e) {
      debugPrint("Error opening $portName: $e");
      closePort();
    }
  }

  static const List<String> _allowedPrefixes = [
    "@DATA",
    "@CFG",
    "@ACK",
    "I (",
    "W (",
    "E (",
  ];

  bool _isAllowedLine(String line) {
    for (final p in _allowedPrefixes) {
      if (line.startsWith(p)) return true;
    }
    return false;
  }

  /// @DATA satırını raw kapalıyken payload'sız hale getir.
  /// Örn:
  ///  @DATA seq=123 us=456 ABCDE...
  /// -> @DATA seq=123 us=456 payload_len=999 (hidden)
  String _sanitizeDataLine(String line) {
    // Zaten "@DATA" ile başlıyor varsayımıyla çağrılıyor.
    // İlk 2 alan genelde "seq=..." ve "us=..." oluyor.
    // Sonrasında payload geliyor.
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length <= 3) {
      // Payload yok gibi; olduğu gibi dön.
      return line;
    }

    // parts[0] = "@DATA"
    // parts[1] = "seq=..."
    // parts[2] = "us=..."
    final head = <String>[parts[0], parts[1], parts[2]].join(' ');

    // Payload uzunluğu: head + 1 boşluk sonrası kalan karakter sayısı
    // Daha doğru olması için line içinde head'i bulup sonrasını ölçelim.
    final idx = line.indexOf(parts[2]);
    if (idx < 0) return "$head payload_hidden";

    // parts[2] bitişi
    final endUs = idx + parts[2].length;
    // endUs'tan sonra bir veya daha fazla boşluk olabilir
    int payloadStart = endUs;
    while (payloadStart < line.length && line[payloadStart] == ' ') {
      payloadStart++;
    }

    final payloadLen = (payloadStart < line.length) ? (line.length - payloadStart) : 0;
    return "$head payload_len=$payloadLen (hidden)";
  }

  void _processData(Uint8List data) {
    _buffer += String.fromCharCodes(data);

    // Çok satırlı akış: \n ile ayır
    if (_buffer.contains('\n')) {
      final parts = _buffer.split('\n');
      _buffer = parts.removeLast();

      for (var p in parts) {
        String line = p.trimRight();
        if (line.isEmpty) continue;

        if (!showRawPayload) {
          // 1) Allowed filter
          if (!_isAllowedLine(line)) continue;

          // 2) @DATA özel: payload'ı tamamen gizle
          if (line.startsWith("@DATA")) {
            line = _sanitizeDataLine(line);
          } else {
            // 3) Diğer allowed satırlar: kırp
            if (line.length > 140) {
              line = '${line.substring(0, 140)}… (truncated)';
            }
          }
        } else {
          // Raw açık: yine de UI kilitlenmesin diye 500 char kırp
          if (line.length > 500) {
            line = '${line.substring(0, 500)}… (truncated)';
          }
        }

        lines.add(line);
      }

      if (lines.length > 200) {
        lines = lines.sublist(lines.length - 200);
      }
    }
  }

  void closePort() {
    subscription?.cancel();
    subscription = null;
    reader?.close();
    reader = null;
    if (port != null && port!.isOpen) {
      port!.close();
    }
    port?.dispose();
    port = null;
    isOpen = false;
  }

  void dispose() {
    closePort();
  }

  bool get isNew => DateTime.now().difference(createdAt).inSeconds < 5;
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final Map<String, DeviceModel> _devices = {};
  List<String> _availableCache = [];
  Timer? _scanTimer;
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    _scanTimer = Timer.periodic(const Duration(seconds: 1), (_) => _scanPorts());
    _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _updateUIAndStatus());
    _scanPorts();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _uiTimer?.cancel();
    for (var dev in _devices.values) {
      dev.dispose();
    }
    super.dispose();
  }

  void _scanPorts() {
    _availableCache = SerialPort.availablePorts;
    for (var portName in _availableCache) {
      _devices.putIfAbsent(portName, () => DeviceModel(portName));
    }
    _updateUIAndStatus();
  }

  void _updateUIAndStatus() {
    final now = DateTime.now();
    for (var dev in _devices.values) {
      // Port hâlâ sistemde mi?
      if (!_availableCache.contains(dev.portName)) {
        if (dev.isOpen) dev.closePort();
        dev.status = DeviceStatus.disconnected;
      } else {
        if (dev.isOpen) {
          final msSinceLastRx = dev.lastRx == null ? 1000 : now.difference(dev.lastRx!).inMilliseconds;
          dev.status = (msSinceLastRx < 1000) ? DeviceStatus.connected : DeviceStatus.stale;
        } else {
          dev.status = DeviceStatus.disconnected;
        }
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('C6Tools - Detected devices: ${_devices.length}'),
        actions: [
          Row(
            children: [
              const Text('Show raw payload'),
              Switch(
                value: showRawPayload,
                onChanged: (val) {
                  setState(() {
                    showRawPayload = val;
                  });
                },
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _scanPorts,
            tooltip: 'Rescan',
          )
        ],
      ),
      body: _devices.isEmpty
          ? const Center(
              child: Text(
                "No devices found. Plug in a USB serial device.",
                style: TextStyle(fontSize: 18),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final crossAxisCount = (constraints.maxWidth / 400).floor().clamp(1, 4);
                return GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    childAspectRatio: 0.8,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: _devices.length,
                  itemBuilder: (context, index) {
                    final dev = _devices.values.elementAt(index);
                    return _buildDeviceCard(dev);
                  },
                );
              },
            ),
    );
  }

  Widget _buildDeviceCard(DeviceModel dev) {
    Color cardColor;
    String statusText;
    switch (dev.status) {
      case DeviceStatus.connected:
        cardColor = Colors.green.shade900;
        statusText = 'CONNECTED';
        break;
      case DeviceStatus.stale:
        cardColor = Colors.orange.shade800;
        statusText = 'STALE';
        break;
      case DeviceStatus.disconnected:
        cardColor = Colors.grey.shade900;
        statusText = 'DISCONNECTED';
        break;
    }

    String lastRxStr = 'never';
    if (dev.lastRx != null) {
      final ms = DateTime.now().difference(dev.lastRx!).inMilliseconds;
      lastRxStr = (ms < 1000) ? '$ms ms ago' : '${(ms / 1000).toStringAsFixed(1)} sn ago';
    }

    return Card(
      color: cardColor,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  dev.portName,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                if (dev.isNew && !dev.isOpen)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(4)),
                    child: const Text(
                      'NEW',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Status: $statusText', style: const TextStyle(fontWeight: FontWeight.w600)),
            Text('Last seen: $lastRxStr'),
            Text('Rx Bytes: ${dev.rxBytes}'),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: dev.isOpen ? Colors.red.shade800 : Colors.blue.shade700,
                  foregroundColor: Colors.white,
                ),
                icon: Icon(dev.isOpen ? Icons.close : Icons.usb),
                onPressed: () {
                  if (dev.isOpen) {
                    dev.closePort();
                  } else {
                    dev.openPort();
                  }
                  _updateUIAndStatus();
                },
                label: Text(dev.isOpen ? 'Close Port' : 'Open Port'),
              ),
            ),
            const SizedBox(height: 8),
            const Divider(),
            const Text(
              'Tail Log (last 200 lines):',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey.shade800),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    dev.lines.join('\n'),
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: Colors.greenAccent),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}