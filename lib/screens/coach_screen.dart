import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:path_provider/path_provider.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/ui_kit.dart';

/// Локальный ИИ-тренер. Модель (.gguf) лежит на телефоне, интернет не нужен.
/// Based on GymMane by InlitX.

class _Msg {
  _Msg(this.role, this.text);
  final String role; // 'user' | 'assistant'
  String text;
}

class CoachScreen extends StatefulWidget {
  const CoachScreen({super.key});

  @override
  State<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends State<CoachScreen> {
  // static: модель и чат живут, пока открыто приложение
  static final LlamaController _llm = LlamaController();
  static bool _modelLoaded = false;
  static final List<_Msg> _msgs = [];

  final _input = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<String>? _sub;
  bool _loading = false;
  bool _busy = false;
  String? _error;

  static const _systemPrompt =
      'Ты персональный тренер для новичка в тренажёрном зале. '
      'Отвечай по-русски, коротко (до 5 предложений), простыми словами. '
      'Давай безопасные советы, напоминай про технику и разминку. '
      'Не ставь диагнозы: при боли или травме посоветуй обратиться к врачу. '
      'Если не уверен, так и скажи.';

  /// TODO: сюда подставим данные из приложения (тренировки, вес, рекорды).
  String _trainingSummary() => '';

  @override
  void initState() {
    super.initState();
    if (!_modelLoaded) _tryLoadSaved();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<File> _modelFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/coach.gguf');
  }

  Future<void> _tryLoadSaved() async {
    final f = await _modelFile();
    if (await f.exists()) await _load(f.path);
  }

  Future<void> _pick() async {
    final res = await FilePicker.platform.pickFiles();
    final src = res?.files.single.path;
    if (src == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dst = await _modelFile();
      await File(src).copy(dst.path);
      await _load(dst.path);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _load(String path) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      await _llm.loadModel(modelPath: path, threads: 4, contextSize: 2048);
      _modelLoaded = true;
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _busy || !_modelLoaded) return;
    _input.clear();
    final reply = _Msg('assistant', '');
    setState(() {
      _msgs
        ..add(_Msg('user', text))
        ..add(reply);
      _busy = true;
    });

    final summary = _trainingSummary();
    final sys = summary.isEmpty
        ? _systemPrompt
        : '$_systemPrompt\nДанные ученика:\n$summary';
    final past = _msgs.where((m) => m.text.isNotEmpty).toList();
    final recent = past.length > 8 ? past.sublist(past.length - 8) : past;
    final history = <ChatMessage>[
      ChatMessage(role: 'system', content: sys),
      for (final m in recent) ChatMessage(role: m.role, content: m.text),
    ];

    _sub = _llm
        .generateChat(
          messages: history,
          template: 'chatml',
          maxTokens: 300,
          temperature: 0.7,
        )
        .listen(
      (tok) {
        if (!mounted) return;
        setState(() => reply.text += tok);
        _toBottom();
      },
      onDone: () {
        if (mounted) setState(() => _busy = false);
      },
      onError: (Object e) {
        if (mounted) {
          setState(() {
            _busy = false;
            reply.text += '\n[ошибка: $e]';
          });
        }
      },
    );
  }

  void _stop() {
    _sub?.cancel();
    _llm.stop();
    setState(() => _busy = false);
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.gc;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenHeader(
                title: 'Тренер',
                onBack: () => Navigator.of(context).pop(),
                titleSize: 22,
                subtitle: 'Локальная модель, без интернета',
              ),
              const SizedBox(height: 16),
              Expanded(child: _modelLoaded ? _chat(gc) : _setup(gc)),
              if (_modelLoaded) _inputBar(gc),
            ],
          ),
        ),
      ),
    );
  }

  Widget _setup(GymColors gc) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
          _loading ? 'Загружаю модель…' : 'Выбери файл модели (.gguf)',
          textAlign: TextAlign.center,
          style: AppTheme.f(15, weight: FontWeight.w600, color: gc.text),
        ),
        const SizedBox(height: 16),
        if (_loading)
          const CircularProgressIndicator()
        else
          Pressable(
            onTap: _pick,
            scale: 0.96,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              decoration: BoxDecoration(
                  color: gc.bgRaised, borderRadius: BorderRadius.circular(20)),
              child: Text('Выбрать файл',
                  style: AppTheme.f(14.5,
                      weight: FontWeight.w700, color: gc.text)),
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!,
              textAlign: TextAlign.center,
              style: AppTheme.f(12, color: gc.textSecondary)),
        ],
      ]),
    );
  }

  Widget _chat(GymColors gc) {
    if (_msgs.isEmpty) {
      return Center(
        child: Text(
          'Спроси тренера, например:\n«Составь план на 3 дня для новичка»',
          textAlign: TextAlign.center,
          style: AppTheme.f(14, color: gc.textSecondary, height: 1.4),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: _msgs.length,
      itemBuilder: (context, i) {
        final m = _msgs[i];
        final mine = m.role == 'user';
        return Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.82),
            decoration: BoxDecoration(
              color: mine ? gc.bgRaised : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              m.text.isEmpty ? '…' : m.text,
              style: AppTheme.f(14,
                  weight: FontWeight.w500, color: gc.text, height: 1.4),
            ),
          ),
        );
      },
    );
  }

  Widget _inputBar(GymColors gc) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _input,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            style: AppTheme.f(14, color: gc.text),
            decoration: InputDecoration(
              hintText: 'Сообщение тренеру',
              filled: true,
              fillColor: gc.bgRaised,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(22),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: _busy ? _stop : _send,
          icon: Icon(
              _busy ? Icons.stop_circle_rounded : Icons.arrow_upward_rounded),
        ),
      ]),
    );
  }
}