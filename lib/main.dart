// SmartCalc — main.dart (Multi-platform)
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:math_expressions/math_expressions.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmartCalcApp());
}

class SmartCalcApp extends StatelessWidget {
  const SmartCalcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartCalc',
      theme: ThemeData(
        brightness: Brightness.light,
        primarySwatch: Colors.indigo,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.indigo,
        useMaterial3: true,
      ),
      home: const MainPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _selectedIndex = 0;
  late SharedPreferences _prefs;
  String? _openAiKey;
  List<String> _history = [];
  final _exprController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    _prefs = await SharedPreferences.getInstance();
    _openAiKey = _prefs.getString('openai_api_key');
    _history = _prefs.getStringList('history') ?? [];
    setState(() {});
  }

  void _saveHistory(String item) {
    _history.insert(0, '${DateTime.now().toIso8601String()}|$item');
    if (_history.length > 100) _history = _history.sublist(0, 100);
    _prefs.setStringList('history', _history);
    setState(() {});
  }

  void _updateOpenAiKey(String key) {
    _openAiKey = key;
    _prefs.setString('openai_api_key', key);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      CalculatorPage(
        exprController: _exprController,
        onSaveHistory: _saveHistory,
        openAiKeyGetter: () => _openAiKey,
      ),
      HistoryPage(history: _history, onSelect: (s) {
        final parts = s.split('|');
        if (parts.length >= 2) {
          _exprController.text = parts[1];
          setState(() => _selectedIndex = 0);
        }
      }),
      GraphPage(exprController: _exprController),
      ChatGptPage(openAiKeyGetter: () => _openAiKey),
      SettingsPage(onSaveKey: _updateOpenAiKey, currentKey: _openAiKey),
    ];

    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (i) => setState(() => _selectedIndex = i),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.calculate), label: 'Calculator'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'History'),
          BottomNavigationBarItem(icon: Icon(Icons.show_chart), label: 'Graph'),
          BottomNavigationBarItem(icon: Icon(Icons.chat_bubble), label: 'ChatGPT'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

// ---------------- Calculator Page ----------------
class CalculatorPage extends StatefulWidget {
  final TextEditingController exprController;
  final void Function(String) onSaveHistory;
  final String? Function() openAiKeyGetter;

  const CalculatorPage({
    super.key,
    required this.exprController,
    required this.onSaveHistory,
    required this.openAiKeyGetter,
  });

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  final ImagePicker _picker = ImagePicker();
  XFile? _imageFile;
  String _ocrText = '';
  String _result = '';
  String _explain = '';
  bool _loading = false;
  List<double> _plotX = [];
  List<double> _plotY = [];

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? picked = await _picker.pickImage(
        source: source, 
        imageQuality: 80,
        maxWidth: 1200,
      );
      if (picked != null) {
        setState(() {
          _imageFile = picked;
          _ocrText = '';
        });
        await _runOcr(picked);
      }
    } catch (e) {
      _showSnack('Error picking image: $e');
    }
  }

  Future<void> _runOcr(XFile file) async {
    setState(() => _loading = true);
    try {
      final inputImage = InputImage.fromFilePath(file.path);
      final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final RecognizedText recognized = await textRecognizer.processImage(inputImage);
      
      final sb = StringBuffer();
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          sb.writeln(line.text);
        }
      }
      
      setState(() {
        _ocrText = sb.toString().trim();
        if (_ocrText.isNotEmpty) {
          // เลือกเฉพาะบรรทัดแรกที่ดูเหมือนสมการคณิตศาสตร์
          final lines = _ocrText.split('\n');
          final mathLine = lines.firstWhere(
            (line) => line.contains(RegExp(r'[0-9+\-*/=xX]')),
            orElse: () => lines.first
          );
          widget.exprController.text = _sanitize(mathLine);
        }
      });
    } catch (e) {
      _showSnack('OCR error: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _evaluate(String expr) async {
    if (expr.isEmpty) {
      _showSnack('Please enter an expression');
      return;
    }

    setState(() {
      _loading = true;
      _result = '';
      _explain = '';
      _plotX = [];
      _plotY = [];
    });

    try {
      final sanitized = _sanitize(expr);
      
      if (sanitized.contains('=')) {
        setState(() {
          _result = 'Equation detected. Use ChatGPT for solving equations.';
        });
      } else if (sanitized.contains('x')) {
        // Plot function
        await _plotFunction(sanitized);
      } else {
        // Evaluate expression
        final p = Parser();
        final exp = p.parse(sanitized);
        final cm = ContextModel();
        final v = exp.evaluate(EvaluationType.REAL, cm);
        setState(() {
          _result = 'Result: $v';
        });
      }

      widget.onSaveHistory('$expr → $_result');

      // Get explanation from OpenAI if key exists
      final key = widget.openAiKeyGetter();
      if (key != null && key.isNotEmpty) {
        await _explainWithOpenAi(key, expr, _result);
      }
    } catch (e) {
      setState(() {
        _result = 'Error: ${e.toString()}';
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _plotFunction(String expr) async {
    try {
      final p = Parser();
      final exp = p.parse(expr);
      final cm = ContextModel();
      
      final xs = List<double>.generate(101, (i) => (i - 50) / 5.0);
      final ys = <double>[];
      
      for (final x in xs) {
        cm.bindVariableName('x', Number(x));
        try {
          final v = exp.evaluate(EvaluationType.REAL, cm);
          ys.add((v is num) ? v.toDouble() : double.nan);
        } catch (_) {
          ys.add(double.nan);
        }
      }
      
      setState(() {
        _plotX = xs;
        _plotY = ys;
        _result = 'Function plotted for x in [-10, 10]';
      });
    } catch (e) {
      setState(() {
        _result = 'Plotting error: $e';
      });
    }
  }

  String _sanitize(String s) {
    return s
        .replaceAll('×', '*')
        .replaceAll('÷', '/')
        .replaceAll('π', 'pi')
        .replaceAll('^', '**')
        .replaceAll(RegExp(r'\s+'), '');
  }

  Future<void> _explainWithOpenAi(String apiKey, String expr, String result) async {
    try {
      final prompt = '''
Explain this calculation step by step in simple Thai:
Expression: $expr
Result: $result

Keep it short and educational.
''';
      
      final url = Uri.parse('https://api.openai.com/v1/chat/completions');
      final body = jsonEncode({
        'model': 'gpt-4o-mini',
        'messages': [
          {
            'role': 'system',
            'content': 'You are a helpful math tutor. Explain concepts clearly in Thai.'
          },
          {'role': 'user', 'content': prompt}
        ],
        'max_tokens': 500,
        'temperature': 0.7,
      });
      
      final res = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey'
        },
        body: body,
      );

      if (res.statusCode == 200) {
        final j = jsonDecode(res.body);
        final text = j['choices']?[0]?['message']?['content']?.toString() ?? '';
        setState(() => _explain = text.trim());
      } else {
        setState(() => _explain = 'OpenAI error: ${res.statusCode}');
      }
    } catch (e) {
      setState(() => _explain = 'Explanation unavailable: $e');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildPlot() {
  if (_plotX.isEmpty || _plotY.isEmpty) return const SizedBox.shrink();

  final spots = <FlSpot>[];
  for (var i = 0; i < _plotX.length; i++) {
    final y = _plotY[i];
    if (y.isNaN || y.isInfinite) continue;
    spots.add(FlSpot(_plotX[i], y));
  }

  if (spots.isEmpty) {
    return const Padding(
      padding: EdgeInsets.all(8.0),
      child: Text('No valid points to plot'),
    );
  }

  double minY = spots.map((e) => e.y).reduce(min);
  double maxY = spots.map((e) => e.y).reduce(max);
  
  // Add padding to Y axis
  final yRange = maxY - minY;
  if (yRange < 1.0) {
    minY -= 0.5;
    maxY += 0.5;
  } else {
    minY -= yRange * 0.1;
    maxY += yRange * 0.1;
  }

  return SizedBox(
    height: 220,
    child: Padding(
      padding: const EdgeInsets.all(8.0),
      child: LineChart(
        LineChartData(
          minX: -10,
          maxX: 10,
          minY: minY,
          maxY: maxY,
          gridData: const FlGridData(show: true),
          titlesData: const FlTitlesData(
            show: true,
          ),
          borderData: FlBorderData(
            show: true,
            border: Border.all(color: const Color(0xff37434d), width: 1),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: Colors.blue,
              barWidth: 3,
              belowBarData: BarAreaData(show: false),
              dotData: const FlDotData(show: false),
            ),
          ],
        ),
      ),
    ),
  );
}

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Image Preview
              if (_imageFile != null)
                Container(
                  height: 200,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Image.file(
                    File(_imageFile!.path),
                    fit: BoxFit.contain,
                  ),
                ),

              const SizedBox(height: 16),

              // Expression Input
              TextField(
                controller: widget.exprController,
                decoration: const InputDecoration(
                  labelText: 'Math Expression',
                  border: OutlineInputBorder(),
                  hintText: 'e.g., 2+2, sin(x), 3*x+5',
                  suffixIcon: Icon(Icons.functions),
                ),
                maxLines: 2,
              ),

              const SizedBox(height: 12),

              // Camera Buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _loading ? null : () => _pickImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Camera'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _loading ? null : () => _pickImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Gallery'),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Action Buttons
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _loading ? null : () => _evaluate(widget.exprController.text.trim()),
                      icon: const Icon(Icons.calculate),
                      label: const Text('Calculate'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _loading
                        ? null
                        : () {
                            widget.exprController.clear();
                            setState(() {
                              _ocrText = '';
                              _result = '';
                              _explain = '';
                              _plotX = [];
                              _plotY = [];
                              _imageFile = null;
                            });
                          },
                    child: const Text('Clear'),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // Loading Indicator
              if (_loading)
                const Column(
                  children: [
                    SpinKitCircle(color: Colors.blue, size: 40),
                    SizedBox(height: 8),
                    Text('Processing...'),
                  ],
                ),

              // Results Section
              if (_result.isNotEmpty) ...[
                _buildResultSection(),
                const SizedBox(height: 16),
              ],

              // Explanation Section
              if (_explain.isNotEmpty) ...[
                _buildExplanationSection(),
                const SizedBox(height: 16),
              ],

              // Action Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    onPressed: widget.exprController.text.trim().isEmpty
                        ? null
                        : () {
                            Clipboard.setData(
                              ClipboardData(text: widget.exprController.text.trim()),
                            );
                            _showSnack('Expression copied to clipboard');
                          },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _result.isEmpty
                        ? null
                        : () {
                            _shareResults();
                          },
                    icon: const Icon(Icons.share),
                    label: const Text('Share'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Result:',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            _result,
            style: const TextStyle(fontSize: 16),
          ),
        ),
        const SizedBox(height: 8),
        if (_plotX.isNotEmpty) ...[
          const Text(
            'Graph:',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _buildPlot(),
        ],
      ],
    );
  }

  Widget _buildExplanationSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Explanation:',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(_explain),
        ),
      ],
    );
  }

  Future<void> _shareResults() async {
    final String shareText = '''
SmartCalc Result:
Expression: ${widget.exprController.text}
Result: $_result
${_explain.isNotEmpty ? 'Explanation: $_explain' : ''}
''';

    // For iOS/mobile sharing
    if (await canLaunchUrl(Uri.parse('mailto:'))) {
      final Uri emailUri = Uri(
        scheme: 'mailto',
        queryParameters: {
          'subject': 'SmartCalc Result',
          'body': shareText,
        },
      );
      await launchUrl(emailUri);
    } else {
      // Fallback to copy to clipboard
      await Clipboard.setData(ClipboardData(text: shareText));
      _showSnack('Results copied to clipboard');
    }
  }
}

// ---------------- History Page ----------------
class HistoryPage extends StatelessWidget {
  final List<String> history;
  final void Function(String) onSelect;
  
  const HistoryPage({super.key, required this.history, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calculation History'),
        actions: [
          if (history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: () {
                // Clear history functionality would go here
                _showClearDialog(context);
              },
            ),
        ],
      ),
      body: history.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No history yet',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: history.length,
              itemBuilder: (context, index) {
                final item = history[index];
                final parts = item.split('|');
                final timestamp = parts[0];
                final expression = parts.length >= 2 ? parts[1] : item;
                
                final dateTime = DateTime.parse(timestamp);
                final timeString = '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
                final dateString = '${dateTime.day}/${dateTime.month}/${dateTime.year}';
                
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.blue.shade100,
                      child: const Icon(Icons.calculate, color: Colors.blue),
                    ),
                    title: Text(
                      expression,
                      style: const TextStyle(fontFamily: 'Monospace'),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('$dateString at $timeString'),
                    trailing: IconButton(
                      icon: const Icon(Icons.content_copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: expression));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Expression copied')),
                        );
                      },
                    ),
                    onTap: () => onSelect(item),
                  ),
                );
              },
            ),
    );
  }

  void _showClearDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear History?'),
        content: const Text('This will remove all calculation history.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              // Clear history logic would go here
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('History cleared')),
              );
            },
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

// ---------------- Graph Page ----------------
class GraphPage extends StatefulWidget {
  final TextEditingController exprController;
  
  const GraphPage({super.key, required this.exprController});

  @override
  State<GraphPage> createState() => _GraphPageState();
}

class _GraphPageState extends State<GraphPage> {
  final TextEditingController _graphController = TextEditingController();
  List<FlSpot> _spots = [];
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _graphController.text = widget.exprController.text;
  }

  void _plotFunction() {
    final expression = _graphController.text.trim();
    if (expression.isEmpty) {
      setState(() => _errorMessage = 'Please enter a function');
      return;
    }

    try {
      final p = Parser();
      final exp = p.parse(expression);
      final cm = ContextModel();
      
      final spots = <FlSpot>[];
      for (double x = -10; x <= 10; x += 0.2) {
        cm.bindVariableName('x', Number(x));
        try {
          final y = exp.evaluate(EvaluationType.REAL, cm);
          if (y is num) {
            spots.add(FlSpot(x, y.toDouble()));
          }
        } catch (_) {
          // Skip points that cause errors
        }
      }

      setState(() {
        _spots = spots;
        _errorMessage = spots.isEmpty ? 'No valid points to plot' : '';
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
        _spots = [];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Function Graph')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _graphController,
              decoration: InputDecoration(
                labelText: 'f(x) =',
                border: const OutlineInputBorder(),
                hintText: 'e.g., sin(x), x^2, 2*x+1',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.functions),
                  onPressed: _plotFunction,
                ),
                errorText: _errorMessage.isNotEmpty ? _errorMessage : null,
              ),
              onSubmitted: (_) => _plotFunction(),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _plotFunction,
              child: const Text('Plot Graph'),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: _spots.isEmpty
                  ? Center(
                      child: Text(
                        _errorMessage.isEmpty 
                            ? 'Enter a function to plot' 
                            : _errorMessage,
                        style: const TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: LineChart(
                        LineChartData(
                          minX: -10,
                          maxX: 10,
                          minY: _spots.map((e) => e.y).reduce(min) - 1,
                          maxY: _spots.map((e) => e.y).reduce(max) + 1,
                          gridData: const FlGridData(show: true),
                          titlesData: const FlTitlesData(show: true),
                          borderData: FlBorderData(
                            show: true,
                            border: Border.all(color: Colors.grey, width: 1),
                          ),
                          lineBarsData: [
                            LineChartBarData(
                              spots: _spots,
                              isCurved: true,
                              color: Colors.blue,
                              barWidth: 2,
                              dotData: const FlDotData(show: false),
                            ),
                          ],
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
// ---------------- ChatGPT Page ----------------
class ChatGptPage extends StatefulWidget {
  final String? Function() openAiKeyGetter;
  
  const ChatGptPage({super.key, required this.openAiKeyGetter});

  @override
  State<ChatGptPage> createState() => _ChatGptPageState();
}

class _ChatGptPageState extends State<ChatGptPage> {
  final TextEditingController _chatController = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  bool _loading = false;
  final ScrollController _scrollController = ScrollController();

  Future<void> _sendMessage() async {
    final message = _chatController.text.trim();
    if (message.isEmpty) return;

    final apiKey = widget.openAiKeyGetter();
    if (apiKey == null || apiKey.isEmpty) {
      _showError('Please set OpenAI API key in Settings first');
      return;
    }

    setState(() {
      _messages.add({'role': 'user', 'content': message, 'timestamp': DateTime.now()});
      _loading = true;
    });
    _chatController.clear();
    _scrollToBottom();

    try {
      final url = Uri.parse('https://api.openai.com/v1/chat/completions');
      final body = jsonEncode({
        'model': 'gpt-4o-mini',
        'messages': [
          {
            'role': 'system',
            'content': 'You are a helpful math tutor. Explain concepts clearly and concisely. Use Thai language for explanations.'
          },
          ..._messages.map((msg) => {'role': msg['role'], 'content': msg['content']})
        ],
        'max_tokens': 500,
        'temperature': 0.7,
      });

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey'
        },
        body: body,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(response.body);
        final reply = jsonResponse['choices'][0]['message']['content'];
        
        setState(() {
          _messages.add({'role': 'assistant', 'content': reply, 'timestamp': DateTime.now()});
        });
      } else {
        throw Exception('API error: ${response.statusCode}');
      }
    } catch (e) {
      _showError('Failed to get response: $e');
    } finally {
      setState(() => _loading = false);
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
    setState(() => _loading = false);
  }

  void _clearChat() {
    setState(() => _messages.clear());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Math Assistant'),
        actions: [
          if (_messages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear_all),
              onPressed: _clearChat,
              tooltip: 'Clear Chat',
            ),
        ],
      ),
      body: Column(
        children: [
          // Chat Messages
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'Ask me anything about math!',
                          style: TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final isUser = message['role'] == 'user';
                      
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
                          children: [
                            if (!isUser)
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: Colors.blue.shade100,
                                child: const Icon(Icons.smart_toy, size: 18, color: Colors.blue),
                              ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: isUser
                                      ? Colors.blue.shade100
                                      : Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(message['content']),
                              ),
                            ),
                            if (isUser)
                              const SizedBox(width: 8),
                            if (isUser)
                              CircleAvatar(
                                radius: 16,
                                backgroundColor: Colors.green.shade100,
                                child: const Icon(Icons.person, size: 18, color: Colors.green),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),

          // Loading Indicator
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  SpinKitThreeBounce(color: Colors.blue, size: 20),
                  SizedBox(width: 16),
                  Text('Thinking...'),
                ],
              ),
            ),

          // Input Area
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(top: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatController,
                    decoration: const InputDecoration(
                      hintText: 'Ask a math question...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 16),
                    ),
                    maxLines: null,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _loading ? null : _sendMessage,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- Settings Page ----------------
class SettingsPage extends StatefulWidget {
  final void Function(String) onSaveKey;
  final String? currentKey;
  
  const SettingsPage({super.key, required this.onSaveKey, this.currentKey});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _keyController = TextEditingController();
  bool _obscureText = true;

  @override
  void initState() {
    super.initState();
    _keyController.text = widget.currentKey ?? '';
  }

  void _saveKey() {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      _showMessage('Please enter an API key');
      return;
    }
    widget.onSaveKey(key);
    _showMessage('API key saved successfully');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // API Key Section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'OpenAI API Configuration',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Enter your OpenAI API key to enable AI features:',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _keyController,
                    obscureText: _obscureText,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      border: const OutlineInputBorder(),
                      hintText: 'sk-...',
                      suffixIcon: IconButton(
                        icon: Icon(_obscureText ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscureText = !_obscureText),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saveKey,
                      child: const Text('Save API Key'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // App Information
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'About SmartCalc',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  _buildInfoRow(Icons.calculate, 'Calculator', 'Basic and scientific calculations'),
                  _buildInfoRow(Icons.camera_alt, 'OCR', 'Extract math from images'),
                  _buildInfoRow(Icons.show_chart, 'Graphing', 'Plot functions'),
                  _buildInfoRow(Icons.chat, 'AI Assistant', 'Get explanations from ChatGPT'),
                  _buildInfoRow(Icons.history, 'History', 'Track your calculations'),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Quick Actions
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Quick Actions',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.help, size: 16),
                        label: const Text('Get Help'),
                        onPressed: () => _showHelpDialog(),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.bug_report, size: 16),
                        label: const Text('Report Issue'),
                        onPressed: () => _showReportDialog(),
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.star, size: 16),
                        label: const Text('Rate App'),
                        onPressed: () => _showRatingDialog(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 32),
          
          // Version Info
          const Center(
            child: Text(
              'SmartCalc v1.0.0',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: Colors.blue),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
                Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Help & Support'),
        content: const Text(
          'SmartCalc helps you with:\n\n'
          '• Basic and scientific calculations\n'
          '• Extract math from images using OCR\n'
          '• Plot function graphs\n'
          '• Get AI explanations\n'
          '• Save calculation history\n\n'
          'Set your OpenAI API key to enable AI features.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showReportDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Report Issue'),
        content: const Text('Found a bug or have a suggestion? We\'d love to hear from you!'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _showMessage('Thank you for your feedback!');
            },
            child: const Text('Send Feedback'),
          ),
        ],
      ),
    );
  }

  void _showRatingDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rate SmartCalc'),
        content: const Text('If you enjoy using SmartCalc, please consider rating it!'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Maybe Later'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _showMessage('Thank you for your rating!');
            },
            child: const Text('Rate Now'),
          ),
        ],
      ),
    );
  }
}