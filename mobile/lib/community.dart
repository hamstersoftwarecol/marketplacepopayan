import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';

void _notice(BuildContext c, Object e) {
  if (c.mounted) {
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$e')));
  }
}

class Conversations extends StatefulWidget {
  final Marketplace store;
  const Conversations({super.key, required this.store});
  @override
  State<Conversations> createState() => _ConversationsState();
}

class _ConversationsState extends State<Conversations> {
  List<dynamic> items = [];
  Object? error;
  bool loading = true;
  int revision = -1;
  String? userId;
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_changed);
    _load();
  }

  void _changed() {
    if (revision != widget.store.revision ||
        userId != widget.store.user?['id']) {
      revision = widget.store.revision;
      userId = widget.store.user?['id'];
      _load();
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_changed);
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.store.user == null) {
      if (mounted) {
        setState(() {
          items = [];
          loading = false;
        });
      }
      return;
    }
    try {
      final data = await widget.store.request('GET', '/conversations');
      if (mounted) {
        setState(() {
          items = data;
          error = null;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e;
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.store.user == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Inicia sesión desde Mi cuenta para conversar con vendedores.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Conversaciones',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 20),
          if (error != null)
            TextButton(
              onPressed: _load,
              child: const Text('No se pudo conectar. Reintentar'),
            ),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Abre un producto y toca «Hablar con el vendedor» para iniciar una conversación.',
              ),
            ),
          ...items.map(
            (item) => Card(
              child: ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.chat_bubble_outline),
                ),
                title: Text(item['other_name']),
                subtitle: Text(
                  '${item['title']}\n${item['last_message'] ?? 'Nueva conversación'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                isThreeLine: true,
                trailing: item['unread'] > 0
                    ? Badge(label: Text('${item['unread']}'))
                    : null,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ChatRoom(store: widget.store, conversation: item),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ChatRoom extends StatefulWidget {
  final Marketplace store;
  final Map<String, dynamic> conversation;
  const ChatRoom({super.key, required this.store, required this.conversation});
  @override
  State<ChatRoom> createState() => _ChatRoomState();
}

class _ChatRoomState extends State<ChatRoom> {
  final text = TextEditingController();
  final scroll = ScrollController();
  List<dynamic> items = [];
  List<dynamic> reads = [];
  int? before;
  Object? error;
  bool sending = false;
  String? clientKey;
  String? pendingText;
  int revision = -1;
  bool fetching = false;
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_changed);
    _load();
  }

  void _changed() {
    if (revision != widget.store.revision) {
      revision = widget.store.revision;
      _load();
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_changed);
    text.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool older = false}) async {
    if (fetching) return;
    fetching = true;
    try {
      final result = await widget.store.request(
        'GET',
        '/conversations/${widget.conversation['id']}/messages${older ? '?before=$before' : ''}',
      );
      if (mounted) {
        setState(() {
          items = older ? [...result['items'], ...items] : result['items'];
          reads = result['reads'];
          before = result['before'];
          error = null;
        });
        if (items.isNotEmpty &&
            items.last['sender_id'] != widget.store.user?['id']) {
          await widget.store.request(
            'POST',
            '/conversations/${widget.conversation['id']}/read',
            {'seq': items.last['seq']},
          );
        }
        if (!older) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (scroll.hasClients) {
              scroll.jumpTo(scroll.position.maxScrollExtent);
            }
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      fetching = false;
    }
  }

  Future<void> _send() async {
    if (text.text.trim().isEmpty || sending) return;
    setState(() => sending = true);
    if (pendingText != text.text.trim()) {
      clientKey = const Uuid().v4();
      pendingText = text.text.trim();
    }
    try {
      await widget.store.request(
        'POST',
        '/conversations/${widget.conversation['id']}/messages',
        {'body': pendingText, 'clientKey': clientKey},
      );
      text.clear();
      pendingText = null;
      clientKey = null;
      await _load();
      widget.store.changed();
    } catch (e) {
      if (mounted) _notice(context, e);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.conversation['title'] ?? 'Conversación'),
      actions: [
        PopupMenuButton<String>(
          onSelected: (action) async {
            final me = widget.store.user!['id'];
            final other = widget.conversation['buyer_id'] == me
                ? widget.conversation['seller_id']
                : widget.conversation['buyer_id'];
            try {
              await widget.store.request(
                action == 'unblock' ? 'DELETE' : 'POST',
                '/blocks/$other',
              );
              if (context.mounted) {
                _notice(
                  context,
                  action == 'unblock'
                      ? 'Contacto desbloqueado.'
                      : 'Contacto bloqueado.',
                );
              }
            } catch (e) {
              if (context.mounted) _notice(context, e);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'block', child: Text('Bloquear contacto')),
            PopupMenuItem(
              value: 'unblock',
              child: Text('Desbloquear contacto'),
            ),
          ],
        ),
      ],
    ),
    body: Column(
      children: [
        if (!widget.store.connected)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Reconectando. Los mensajes confirmados se conservarán.',
            ),
          ),
        if (error != null)
          TextButton(
            onPressed: _load,
            child: const Text('No se pudo actualizar. Reintentar'),
          ),
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.all(16),
            children: [
              if (before != null)
                TextButton(
                  onPressed: () => _load(older: true),
                  child: const Text('Mensajes anteriores'),
                ),
              ...items.map((item) {
                final mine = item['sender_id'] == widget.store.user?['id'];
                final read = reads.any(
                  (r) =>
                      r['user_id'] != widget.store.user?['id'] &&
                      r['last_seq'] >= item['seq'],
                );
                return Align(
                  alignment: mine
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 440),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: mine ? const Color(0xFF135E4B) : Colors.white,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          item['body'],
                          style: TextStyle(
                            color: mine ? Colors.white : Colors.black87,
                            fontSize: 16,
                          ),
                        ),
                        if (mine)
                          Text(
                            read ? 'Leído' : 'Enviado',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: text,
                    enabled: !sending,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    decoration: const InputDecoration(
                      hintText: 'Escribe un mensaje',
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: sending ? null : _send,
                  icon: Icon(sending ? Icons.hourglass_empty : Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class FavoritesScreen extends StatefulWidget {
  final Marketplace store;
  final void Function(BuildContext, String) openProduct;
  const FavoritesScreen({
    super.key,
    required this.store,
    required this.openProduct,
  });
  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<dynamic>? items;
  Object? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.store.request('GET', '/favorites');
      if (mounted) {
        setState(() {
          items = data;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Mis favoritos')),
    body: error != null
        ? Center(
            child: TextButton(
              onPressed: _load,
              child: const Text('No se pudo cargar. Reintentar'),
            ),
          )
        : items == null
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (items!.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Guarda productos desde su detalle para verlos aquí.',
                    ),
                  ),
                ...items!.map(
                  (p) => Card(
                    child: ListTile(
                      title: Text(p['title']),
                      subtitle: Text(
                        '${p['zone']} · ${p['status'] == 'active' ? 'Disponible' : 'Pausado'}',
                      ),
                      onTap: () => widget.openProduct(context, p['id']),
                      trailing: IconButton(
                        icon: const Icon(Icons.favorite),
                        onPressed: () async {
                          try {
                            await widget.store.request(
                              'DELETE',
                              '/favorites/${p['id']}',
                            );
                            await _load();
                          } catch (e) {
                            if (context.mounted) _notice(context, e);
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
  );
}

Future<void> reportProduct(
  BuildContext context,
  Marketplace store,
  String id,
) async {
  final controller = TextEditingController();
  final reason = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Reportar publicación'),
      content: TextField(
        controller: controller,
        maxLength: 2000,
        minLines: 3,
        maxLines: 5,
        decoration: const InputDecoration(
          labelText: 'Explica el motivo (mínimo 10 caracteres)',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Volver'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Enviar reporte'),
        ),
      ],
    ),
  );
  if (reason == null) return;
  try {
    await store.request('POST', '/reports', {
      'targetType': 'product',
      'targetId': id,
      'reason': reason,
    });
    if (context.mounted) _notice(context, 'Reporte enviado para revisión.');
  } catch (e) {
    if (context.mounted) _notice(context, e);
  }
}
