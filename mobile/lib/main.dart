import 'dart:async';
import 'dart:convert';

import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'community.dart';

void main() => runApp(const MarketplaceApp());
final money = NumberFormat.currency(
  locale: 'es_CO',
  symbol: r'$',
  decimalDigits: 0,
);
String price(dynamic minor) => money.format((minor as num) / 100);
const green = Color(0xFF135E4B);
const paper = Color(0xFFF6F7F2);
const statuses = {
  'pending': 'Por aceptar',
  'accepted': 'Aceptado',
  'ready': 'Listo para recoger',
  'completed': 'Completado',
  'cancelled': 'Cancelado',
  'rejected': 'Rechazado',
  'expired': 'Vencido',
};
void message(BuildContext context, Object error) {
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

mixin Notices<T extends StatefulWidget> on State<T> {
  void notice(Object e) {
    if (mounted) message(context, e);
  }
}

class MarketplaceApp extends StatefulWidget {
  const MarketplaceApp({super.key});
  @override
  State<MarketplaceApp> createState() => _MarketplaceAppState();
}

class _MarketplaceAppState extends State<MarketplaceApp> with Notices {
  final store = Marketplace();
  @override
  void dispose() {
    store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Marketplace Popayán',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: green,
        primary: green,
        surface: paper,
      ),
      scaffoldBackgroundColor: paper,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
        fillColor: Colors.white,
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    ),
    home: Home(store: store),
  );
}

class Home extends StatefulWidget {
  final Marketplace store;
  const Home({super.key, required this.store});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with Notices {
  int tab = 0;
  Object? startupError;
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() => startupError = null);
    try {
      await widget.store.initialize();
    } catch (e) {
      if (mounted) setState(() => startupError = e);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final store = widget.store;
      return Scaffold(
        appBar: AppBar(
          title: const Row(
            children: [
              Icon(Icons.storefront_rounded, color: green),
              SizedBox(width: 10),
              Text('Popayán', style: TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
          actions: [
            if (store.user != null)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Chip(
                  avatar: Icon(
                    store.connected ? Icons.wifi : Icons.sync,
                    size: 16,
                    color: store.connected ? green : Colors.orange,
                  ),
                  label: Text(
                    store.connected ? 'En vivo' : 'Reconectando',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
        body: !store.initialized
            ? const Center(child: CircularProgressIndicator())
            : startupError != null
            ? Failure(error: startupError!, retry: _initialize)
            : IndexedStack(
                index: tab,
                children: [
                  Catalog(store: store),
                  Orders(store: store),
                  Conversations(store: store),
                  Profile(store: store),
                ],
              ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.explore_outlined),
              selectedIcon: Icon(Icons.explore),
              label: 'Explorar',
            ),
            NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              label: 'Pedidos',
            ),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              label: 'Mensajes',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              label: 'Mi cuenta',
            ),
          ],
        ),
        floatingActionButton: tab == 0 && store.user?['seller'] == 1
            ? FloatingActionButton.extended(
                onPressed: () async {
                  final created = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(builder: (_) => Publish(store: store)),
                  );
                  if (created == true) store.changed();
                },
                icon: const Icon(Icons.add),
                label: const Text('Publicar'),
              )
            : null,
      );
    },
  );
}

class Failure extends StatelessWidget {
  final Object error;
  final VoidCallback retry;
  const Failure({super.key, required this.error, required this.retry});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 44, color: green),
          const SizedBox(height: 16),
          Text(
            error is ApiException ? error.toString() : 'No pudimos conectar con el marketplace. Comprueba la conexión y la dirección del servidor.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: retry, child: const Text('Reintentar')),
        ],
      ),
    ),
  );
}

class Catalog extends StatefulWidget {
  final Marketplace store;
  const Catalog({super.key, required this.store});
  @override
  State<Catalog> createState() => _CatalogState();
}

class _CatalogState extends State<Catalog> with Notices {
  final search = TextEditingController();
  Timer? debounce;
  String category = '';
  List<dynamic> items = [];
  int? next;
  bool loading = true;
  Object? error;
  int requestVersion = 0;
  int revision = -1;
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
    search.dispose();
    debounce?.cancel();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final version = ++requestVersion;
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final query = Uri(
        queryParameters: {
          'q': search.text,
          'category': category,
          'offset': '${more ? next ?? 0 : 0}',
        },
      ).query;
      final result = await widget.store.request('GET', '/products?$query');
      if (mounted && version == requestVersion) {
        setState(() {
          items = more ? [...items, ...result['items']] : result['items'];
          next = result['nextOffset'];
          loading = false;
        });
      }
    } catch (e) {
      if (mounted && version == requestVersion) {
        setState(() {
          error = e;
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null && items.isEmpty) {
      return Failure(error: error!, retry: _load);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: green,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'CERCA DE TI',
                          style: TextStyle(
                            color: Color(0xFFB5D9BD),
                            letterSpacing: 2,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Lo que buscas,\nestá en tu ciudad.',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            height: 1.1,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Compra local. Conecta con Popayán.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: search,
                    onChanged: (_) {
                      debounce?.cancel();
                      debounce = Timer(
                        const Duration(milliseconds: 350),
                        _load,
                      );
                    },
                    decoration: const InputDecoration(
                      hintText: 'Buscar en Popayán',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(18)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        ChoiceChip(
                          label: const Text('Todo'),
                          selected: category.isEmpty,
                          onSelected: (_) {
                            setState(() => category = '');
                            _load();
                          },
                        ),
                        ...widget.store.categories.map(
                          (c) => Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: ChoiceChip(
                              label: Text(c['name']),
                              selected: category == c['id'],
                              onSelected: (_) {
                                setState(() => category = c['id']);
                                _load();
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Descubre lo local',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Productos de personas y negocios de tu ciudad.',
                    style: TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
          if (loading && items.isEmpty)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Aún no hay publicaciones aquí.\nActiva tu perfil vendedor para publicar la primera.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final cols = constraints.crossAxisExtent > 900
                      ? 4
                      : constraints.crossAxisExtent > 600
                      ? 3
                      : 2;
                  return SliverGrid(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final p = items[index];
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ProductDetail(
                                store: widget.store,
                                id: p['id'],
                              ),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Container(
                                  width: double.infinity,
                                  color: const Color(0xFFE6EBDF),
                                  child: ProductPhotos(product: p),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      p['title'],
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      price(p['price_minor']),
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                        color: green,
                                      ),
                                    ),
                                    Text(
                                      '${p['zone']} · ${p['available']} disponibles',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.black54,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }, childCount: items.length),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisExtent: 260,
                      crossAxisSpacing: 4,
                      mainAxisSpacing: 4,
                    ),
                  );
                },
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 90),
              child: Column(
                children: [
                  if (error != null)
                    TextButton(
                      onPressed: () => _load(more: true),
                      child: const Text('No se pudo actualizar. Reintentar'),
                    ),
                  if (next != null)
                    OutlinedButton(
                      onPressed: loading ? null : () => _load(more: true),
                      child: Text(loading ? 'Cargando…' : 'Ver más'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

IconData categoryIcon(dynamic id) => switch (id) {
  'hogar' => Icons.chair_outlined,
  'tecnologia' => Icons.devices_outlined,
  'moda' => Icons.checkroom,
  'deportes' => Icons.sports_basketball_outlined,
  _ => Icons.shopping_bag_outlined,
};

class ProductDetail extends StatefulWidget {
  final Marketplace store;
  final String id;
  const ProductDetail({super.key, required this.store, required this.id});
  @override
  State<ProductDetail> createState() => _ProductDetailState();
}

class _ProductDetailState extends State<ProductDetail> with Notices {
  Map<String, dynamic>? product;
  Object? error;
  bool busy = false;
  int quantity = 1;
  String? purchaseKey;
  int revision = -1;
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
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await widget.store.request('GET', '/products/${widget.id}');
      if (mounted) {
        setState(() {
          product = Map<String, dynamic>.from(p);
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> _buy() async {
    if (widget.store.user == null) {
      await showAuth(context, widget.store);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar pedido'),
        content: Text(
          '$quantity × ${product!['title']}\nTotal: ${price((product!['price_minor'] as int) * quantity)}\n\nRecogida acordada con el vendedor. Pago al recibir. El vendedor tiene 30 minutos para aceptar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Crear pedido'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => busy = true);
    purchaseKey ??= const Uuid().v4();
    try {
      await widget.store.request(
        'POST',
        '/orders',
        {
          'productId': widget.id,
          'quantity': quantity,
          'expectedPriceMinor': product!['price_minor'],
        },
        {'Idempotency-Key': purchaseKey!},
      );
      purchaseKey = null;
      widget.store.changed();
      if (mounted) {
        message(context, 'Pedido creado. Puedes seguirlo en Pedidos.');
      }
    } catch (e) {
      if (e is ApiException && e.status < 500) purchaseKey = null;
      notice(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Detalle del producto')),
    body: error != null
        ? Failure(error: error!, retry: _load)
        : product == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Container(
                height: 220,
                decoration: BoxDecoration(
                  color: const Color(0xFFE6EBDF),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: ProductPhotos(product: product!),
              ),
              const SizedBox(height: 24),
              Text(
                product!['title'],
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                price(product!['price_minor']),
                style: const TextStyle(
                  fontSize: 30,
                  color: green,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${product!['available']} disponibles · ${product!['zone']}',
              ),
              const Divider(height: 32),
              Text(
                product!['description'],
                style: const TextStyle(fontSize: 16, height: 1.6),
              ),
              const SizedBox(height: 24),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                title: Text(product!['seller_name']),
                subtitle: const Text('Vendedor local'),
              ),
              const SizedBox(height: 16),
              if (widget.store.user != null)
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          await widget.store.request(
                            'POST',
                            '/favorites/${widget.id}',
                          );
                          if (context.mounted) {
                            message(context, 'Producto guardado en favoritos.');
                          }
                        } catch (e) {
                          notice(e);
                        }
                      },
                      icon: const Icon(Icons.favorite_border),
                      label: const Text('Guardar'),
                    ),
                    TextButton(
                      onPressed: () =>
                          reportProduct(context, widget.store, widget.id),
                      child: const Text('Reportar'),
                    ),
                  ],
                ),
              if (widget.store.user?['id'] != product!['seller_id']) ...[
                OutlinedButton.icon(
                  onPressed: () async {
                    if (widget.store.user == null) {
                      await showAuth(context, widget.store);
                      return;
                    }
                    try {
                      final conversation = await widget.store.request(
                        'POST',
                        '/conversations',
                        {'productId': widget.id},
                      );
                      if (context.mounted) {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatRoom(
                              store: widget.store,
                              conversation: Map<String, dynamic>.from(
                                conversation,
                              ),
                            ),
                          ),
                        );
                      }
                    } catch (e) {
                      notice(e);
                    }
                  },
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('Hablar con el vendedor'),
                ),

                Row(
                  children: [
                    const Text('Cantidad'),
                    IconButton(
                      onPressed: busy || quantity <= 1
                          ? null
                          : () => setState(() {
                              quantity--;
                              purchaseKey = null;
                            }),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text('$quantity'),
                    IconButton(
                      onPressed:
                          busy ||
                              quantity >= (product!['available'] as int) ||
                              quantity >= 100
                          ? null
                          : () => setState(() {
                              quantity++;
                              purchaseKey = null;
                            }),
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                FilledButton.icon(
                  onPressed:
                      busy ||
                          product!['status'] != 'active' ||
                          product!['available'] == 0
                      ? null
                      : _buy,
                  icon: const Icon(Icons.shopping_bag_outlined),
                  label: Text(
                    busy ? 'Confirmando…' : 'Pedir · pago al recibir',
                  ),
                ),
              ] else
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() => busy = true);
                          try {
                            await widget.store.request(
                              'PATCH',
                              '/products/${widget.id}',
                              {
                                'version': product!['version'],
                                'status': product!['status'] == 'active'
                                    ? 'paused'
                                    : 'active',
                              },
                            );
                            widget.store.changed();
                          } catch (e) {
                            notice(e);
                          } finally {
                            if (mounted) setState(() => busy = false);
                          }
                        },
                  child: Text(
                    product!['status'] == 'active'
                        ? 'Pausar publicación'
                        : 'Activar publicación',
                  ),
                ),
            ],
          ),
  );
}

class Orders extends StatefulWidget {
  final Marketplace store;
  const Orders({super.key, required this.store});
  @override
  State<Orders> createState() => _OrdersState();
}

class _OrdersState extends State<Orders> with Notices {
  List<dynamic> orders = [];
  Object? error;
  bool loading = false;
  String? busy;
  int? next;
  int revision = -1;
  String? userId;
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_changed);
    _load();
  }

  void _changed() {
    if (userId != widget.store.user?['id'] ||
        revision != widget.store.revision) {
      userId = widget.store.user?['id'];
      revision = widget.store.revision;
      _load();
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_changed);
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (widget.store.user == null) {
      if (mounted) setState(() => orders = []);
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.store.request(
        'GET',
        '/orders?offset=${more ? next ?? 0 : 0}',
      );
      if (mounted) {
        setState(() {
          orders = more ? [...orders, ...result['items']] : result['items'];
          next = result['nextOffset'];
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _action(dynamic order, String status) async {
    setState(() => busy = order['id']);
    try {
      await widget.store.request('PATCH', '/orders/${order['id']}', {
        'status': status,
        'version': order['version'],
      });
      widget.store.changed();
    } catch (e) {
      notice(e);
      await _load();
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.store.user == null) {
      return LoginPrompt(
        store: widget.store,
        text: 'Inicia sesión para seguir tus compras y ventas.',
      );
    }
    if (error != null) return Failure(error: error!, retry: _load);
    if (loading && orders.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Tus pedidos',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 28),
          ),
          const SizedBox(height: 6),
          const Text('Compras y ventas, actualizadas en vivo.'),
          const SizedBox(height: 20),
          if (orders.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Aquí aparecerá tu primer pedido. Explora productos de tu ciudad.',
                textAlign: TextAlign.center,
              ),
            ),
          ...orders.map((o) {
            final seller = o['seller_id'] == widget.store.user!['id'];
            final state = o['status'];
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            seller ? 'VENTA' : 'COMPRA',
                            style: const TextStyle(
                              color: green,
                              fontSize: 11,
                              letterSpacing: 2,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Chip(label: Text(statuses[state] ?? state)),
                      ],
                    ),
                    Text(
                      o['title'],
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${o['quantity']} unidades · ${price((o['price_minor'] as int) * (o['quantity'] as int))}',
                    ),
                    Text(
                      'Pedido ${o['id'].toString().substring(0, 8)} · Pago al recibir',
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                      ),
                    ),
                    if (state == 'pending')
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Pendiente de respuesta del vendedor. Reserva de 30 minutos.',
                        ),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (seller && state == 'pending') ...[
                          _button(o, 'accepted', 'Aceptar'),
                          _button(o, 'rejected', 'Rechazar'),
                        ],
                        if (seller && state == 'accepted')
                          _button(o, 'ready', 'Listo para recoger'),
                        if (!seller && state == 'ready')
                          _button(o, 'completed', 'Confirmar recepción'),
                        if (['pending', 'accepted', 'ready'].contains(state))
                          _button(o, 'cancelled', 'Cancelar'),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
          if (next != null)
            TextButton(
              onPressed: loading ? null : () => _load(more: true),
              child: const Text('Ver más'),
            ),
        ],
      ),
    );
  }

  Widget _button(dynamic o, String status, String label) => OutlinedButton(
    onPressed: busy != null ? null : () => _action(o, status),
    child: Text(label),
  );
}

class LoginPrompt extends StatelessWidget {
  final Marketplace store;
  final String text;
  const LoginPrompt({super.key, required this.store, required this.text});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.storefront_outlined, size: 64, color: green),
          const SizedBox(height: 20),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => showAuth(context, store),
            child: const Text('Entrar o crear cuenta'),
          ),
        ],
      ),
    ),
  );
}

class Profile extends StatefulWidget {
  final Marketplace store;
  const Profile({super.key, required this.store});
  @override
  State<Profile> createState() => _ProfileState();
}

class _ProfileState extends State<Profile> with Notices {
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    final user = widget.store.user;
    if (user == null) {
      return LoginPrompt(
        store: widget.store,
        text: 'Compra y vende con tu comunidad.',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const CircleAvatar(
          radius: 40,
          child: Icon(Icons.person_outline, size: 40),
        ),
        const SizedBox(height: 20),
        Text(
          user['name'],
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        Text(user['email'], textAlign: TextAlign.center),
        const SizedBox(height: 24),
        Card(
          child: SwitchListTile(
            title: const Text('Perfil vendedor'),
            subtitle: const Text('Actívalo para publicar productos.'),
            value: user['seller'] == 1,
            onChanged: busy
                ? null
                : (value) async {
                    setState(() => busy = true);
                    try {
                      await widget.store.updateProfile(
                        user['name'],
                        user['zone'],
                        value,
                      );
                    } catch (e) {
                      notice(e);
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.location_on_outlined),
          title: Text(user['zone']),
          subtitle: const Text('Zona del perfil'),
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Editar perfil'),
          onTap: () => _edit(user),
        ),
        ListTile(
          leading: const Icon(Icons.favorite_border),
          title: const Text('Mis favoritos'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => FavoritesScreen(
                store: widget.store,
                openProduct: (context, id) => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProductDetail(store: widget.store, id: id),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() => busy = true);
                  try {
                    await widget.store.logout();
                  } catch (e) {
                    notice(e);
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: const Text('Cerrar sesión'),
        ),
      ],
    );
  }

  Future<void> _edit(Map<String, dynamic> user) async {
    final name = TextEditingController(text: user['name']),
        zone = TextEditingController(text: user['zone']);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Editar perfil'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Nombre'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: zone,
              decoration: const InputDecoration(labelText: 'Zona'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (result == true) {
      try {
        await widget.store.updateProfile(
          name.text,
          zone.text,
          user['seller'] == 1,
        );
      } catch (e) {
        notice(e);
      }
    }
    // Dialog route may still be finishing its animation; controllers are local to it.
  }
}

Future<void> showAuth(BuildContext context, Marketplace store) =>
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AuthScreen(store: store)),
    );

class AuthScreen extends StatefulWidget {
  final Marketplace store;
  const AuthScreen({super.key, required this.store});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with Notices {
  final email = TextEditingController(),
      password = TextEditingController(),
      name = TextEditingController(),
      code = TextEditingController();
  final form = GlobalKey<FormState>();
  String mode = 'login';
  bool busy = false;
  bool terms = false;
  String? info;
  String? error;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    name.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!form.currentState!.validate()) return;
    if (mode == 'register' && !terms) {
      setState(
        () => error = 'Acepta las condiciones del piloto para continuar.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
      info = null;
    });
    try {
      if (mode == 'login') {
        await widget.store.login(email.text.trim(), password.text);
        if (mounted) Navigator.pop(context);
      } else if (mode == 'register') {
        final result = await widget.store.request('POST', '/auth/register', {
          'email': email.text.trim(),
          'password': password.text,
          'name': name.text.trim(),
          'termsAccepted': true,
        });
        if (mounted) {
          setState(() {
            mode = 'verify';
            info = result['message'];
            code.text = result['developmentCode'] ?? '';
          });
        }
      } else if (mode == 'verify') {
        await widget.store.request('POST', '/auth/verify', {
          'code': code.text.trim(),
        });
        if (mounted) {
          setState(() {
            mode = 'login';
            info = 'Cuenta verificada. Inicia sesión.';
          });
        }
      } else if (mode == 'recover') {
        final result = await widget.store.request(
          'POST',
          '/auth/request-code',
          {'email': email.text.trim(), 'purpose': 'reset'},
        );
        if (mounted) {
          setState(() {
            mode = 'reset';
            info = result['message'];
            code.text = result['developmentCode'] ?? '';
          });
        }
      } else if (mode == 'reset') {
        await widget.store.request('POST', '/auth/reset', {
          'code': code.text.trim(),
          'password': password.text,
        });
        if (mounted) {
          setState(() {
            mode = 'login';
            info = 'Contraseña actualizada. Inicia sesión.';
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final titles = {
      'login': 'Qué bueno verte',
      'register': 'Únete a tu comunidad',
      'verify': 'Verifica tu correo',
      'recover': 'Recupera tu acceso',
      'reset': 'Nueva contraseña',
    };
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Form(
            key: form,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                const Icon(Icons.storefront_rounded, size: 56, color: green),
                const SizedBox(height: 20),
                Text(
                  titles[mode]!,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 24),
                if (info != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(info!),
                  ),
                if (mode == 'register') ...[
                  _field(name, 'Nombre', min: 2),
                  const SizedBox(height: 16),
                ],
                if (['login', 'register', 'recover'].contains(mode)) ...[
                  _field(email, 'Correo electrónico', emailField: true),
                  const SizedBox(height: 16),
                ],
                if (['verify', 'reset'].contains(mode)) ...[
                  _field(code, 'Código recibido por correo', min: 64),
                  const SizedBox(height: 16),
                ],
                if (['login', 'register', 'reset'].contains(mode)) ...[
                  _field(
                    password,
                    mode == 'reset' ? 'Nueva contraseña' : 'Contraseña',
                    secret: true,
                    min: mode == 'login' ? 1 : 12,
                  ),
                  const SizedBox(height: 8),
                  if (mode != 'login')
                    const Text('Usa al menos 12 caracteres.'),
                ],
                if (mode == 'register')
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: terms,
                    onChanged: busy
                        ? null
                        : (v) => setState(() => terms = v ?? false),
                    title: const Text(
                      'Acepto las condiciones del piloto',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: TextButton(
                      onPressed: () => showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Piloto local'),
                          content: const Text(
                            'Compra con recogida acordada y pago al recibir. No publiques productos ilegales ni datos privados. Usamos tu correo para identificarte y conservamos el historial de pedidos. Este entorno es de desarrollo: los textos y la política de datos requieren validación antes de abrir el servicio al público.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Entendido'),
                            ),
                          ],
                        ),
                      ),
                      child: const Text('Leer condiciones'),
                    ),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : _submit,
                  child: Text(
                    busy
                        ? 'Procesando…'
                        : mode == 'login'
                        ? 'Entrar'
                        : mode == 'register'
                        ? 'Crear cuenta'
                        : mode == 'verify'
                        ? 'Verificar cuenta'
                        : mode == 'recover'
                        ? 'Enviar código'
                        : 'Guardar contraseña',
                  ),
                ),
                if (mode == 'login') ...[
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            mode = 'register';
                            error = null;
                          }),
                    child: const Text('Crear una cuenta'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            mode = 'recover';
                            error = null;
                          }),
                    child: const Text('Olvidé mi contraseña'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            mode = 'verify';
                            error = null;
                          }),
                    child: const Text('Ya tengo un código de verificación'),
                  ),
                ] else
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            mode = 'login';
                            error = null;
                          }),
                    child: const Text('Volver a iniciar sesión'),
                  ),
                if (mode == 'verify')
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            try {
                              final result = await widget.store.request(
                                'POST',
                                '/auth/request-code',
                                {
                                  'email': email.text.trim(),
                                  'purpose': 'verify',
                                },
                              );
                              if (mounted) {
                                setState(() {
                                  info = result['message'];
                                  code.text = result['developmentCode'] ?? '';
                                });
                              }
                            } catch (e) {
                              if (mounted) setState(() => error = e.toString());
                            }
                          },
                    child: const Text('Reenviar código'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    int min = 1,
    bool secret = false,
    bool emailField = false,
  }) => TextFormField(
    controller: controller,
    obscureText: secret,
    enabled: !busy,
    keyboardType: emailField ? TextInputType.emailAddress : TextInputType.text,
    autocorrect: !secret,
    decoration: InputDecoration(labelText: label),
    validator: (v) {
      if ((v?.trim().length ?? 0) < min) {
        return 'Ingresa al menos $min caracteres.';
      }
      if (emailField && !(v?.contains('@') ?? false)) {
        return 'Ingresa un correo válido.';
      }
      return null;
    },
  );
}

class Publish extends StatefulWidget {
  final Marketplace store;
  const Publish({super.key, required this.store});
  @override
  State<Publish> createState() => _PublishState();
}

class _PublishState extends State<Publish> with Notices {
  final title = TextEditingController(),
      description = TextEditingController(),
      amount = TextEditingController(),
      stock = TextEditingController(text: '1'),
      zone = TextEditingController(text: 'Popayán');
  final form = GlobalKey<FormState>();
  String? category;
  final List<String> photoIds = [];
  bool uploading = false;
  bool busy = false;
  String? error;
  @override
  void dispose() {
    for (final c in [title, description, amount, stock, zone]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    if (photoIds.length >= 8) return;
    setState(() => uploading = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (file == null) return;
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) throw Exception('No se pudo leer la fotografía.');
      final jpeg = img.encodeJpg(img.bakeOrientation(decoded), quality: 85);
      final result = await widget.store.request('POST', '/photos', {
        'base64': base64Encode(jpeg),
      });
      if (mounted) setState(() => photoIds.add(result['id']));
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  Future<void> _publish() async {
    if (!form.currentState!.validate()) return;
    if (photoIds.isEmpty) {
      setState(() => error = 'Agrega al menos una fotografía.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.store.request('POST', '/products', {
        'title': title.text.trim(),
        'description': description.text.trim(),
        'categoryId': category,
        'photoIds': photoIds,
        'zone': zone.text.trim(),
        'priceMinor': int.parse(amount.text) * 100,
        'available': int.parse(stock.text),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Nueva publicación')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Dale una nueva oportunidad',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                'Describe tu producto con claridad para tu comunidad.',
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: busy || uploading || photoIds.length >= 8
                    ? null
                    : _pickPhoto,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(
                  uploading
                      ? 'Subiendo foto…'
                      : 'Agregar fotos (${photoIds.length}/8)',
                ),
              ),
              if (photoIds.isNotEmpty)
                Wrap(
                  children: photoIds
                      .map(
                        (id) => Chip(
                          label: Text('Foto ${photoIds.indexOf(id) + 1}'),
                          onDeleted: busy
                              ? null
                              : () => setState(() => photoIds.remove(id)),
                        ),
                      )
                      .toList(),
                ),
              const SizedBox(height: 16),
              field(title, 'Título', min: 3, max: 100),
              const SizedBox(height: 16),
              field(description, 'Descripción', min: 10, max: 4000, lines: 4),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(labelText: 'Categoría'),
                items: widget.store.categories
                    .map(
                      (c) => DropdownMenuItem<String>(
                        value: c['id'],
                        child: Text(c['name']),
                      ),
                    )
                    .toList(),
                onChanged: busy ? null : (v) => setState(() => category = v),
                validator: (v) =>
                    v == null ? 'Selecciona una categoría.' : null,
              ),
              const SizedBox(height: 16),
              field(
                amount,
                'Precio en pesos colombianos',
                numeric: true,
                positive: true,
              ),
              const SizedBox(height: 16),
              field(stock, 'Unidades disponibles', numeric: true),
              const SizedBox(height: 16),
              field(zone, 'Zona de recogida', min: 2, max: 80),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: busy || uploading ? null : _publish,
                child: Text(busy ? 'Publicando…' : 'Publicar producto'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget field(
    TextEditingController c,
    String label, {
    int min = 1,
    int max = 100,
    int lines = 1,
    bool numeric = false,
    bool positive = false,
  }) => TextFormField(
    controller: c,
    enabled: !busy,
    maxLines: lines,
    keyboardType: numeric ? TextInputType.number : TextInputType.text,
    decoration: InputDecoration(labelText: label),
    validator: (v) {
      if (numeric) {
        final n = int.tryParse(v ?? '');
        if (n == null ||
            n < (positive ? 1 : 0) ||
            n > (positive ? 1000000000 : 1000000)) {
          return 'Ingresa una cantidad válida.';
        }
      } else if ((v?.trim().length ?? 0) < min || (v?.length ?? 0) > max) {
        return 'Usa entre $min y $max caracteres.';
      }
      return null;
    },
  );
}

class ProductPhotos extends StatelessWidget {
  final Map<String, dynamic> product;
  const ProductPhotos({super.key, required this.product});
  @override
  Widget build(BuildContext context) {
    List<dynamic> ids = [];
    try {
      ids = jsonDecode(product['photo_ids'] ?? '[]');
    } catch (_) {}
    Widget fallback() =>
        Icon(categoryIcon(product['category_id']), size: 64, color: green);
    if (ids.isEmpty) return fallback();
    return PageView(
      children: ids
          .map(
            (id) => Image.network(
              '$apiBase/api/photos/$id',
              fit: BoxFit.cover,
              width: double.infinity,
              errorBuilder: (_, e, s) => fallback(),
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const Center(child: CircularProgressIndicator()),
            ),
          )
          .toList(),
    );
  }
}
