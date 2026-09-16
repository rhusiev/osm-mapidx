/// Bottom-sheet place picker used to set the distance origin.
///
/// The same fuzzy search the main page runs, but with the explicit goal of
/// choosing one place. Returns the chosen Hit, or null if the user cancels.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'index.dart';
import 'search.dart';

Future<Hit?> showFromSheet(BuildContext context, Index index) {
  return showModalBottomSheet<Hit>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) =>
          _FromSheet(index: index, scrollController: scrollController),
    ),
  );
}

class _FromSheet extends StatefulWidget {
  const _FromSheet({required this.index, required this.scrollController});

  final Index index;
  final ScrollController scrollController;

  @override
  State<_FromSheet> createState() => _FromSheetState();
}

class _FromSheetState extends State<_FromSheet> {
  final _typed = TextEditingController();
  Timer? _pending;
  var _hits = const <Hit>[];
  var _searching = false;
  var _hasText = false;

  @override
  void initState() {
    super.initState();
    _typed.addListener(() {
      if (_typed.text.isEmpty != _hasText) {
        setState(() => _hasText = _typed.text.isNotEmpty);
      }
    });
  }

  @override
  void dispose() {
    _pending?.cancel();
    _typed.dispose();
    super.dispose();
  }

  void _typedSomething(String query) {
    _pending?.cancel();
    _pending = Timer(const Duration(milliseconds: 250), () => _find(query));
  }

  Future<void> _find(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _hits = const []);
      return;
    }
    setState(() => _searching = true);
    final hits = await widget.index.find(query, limit: 30);
    if (!mounted) return;
    setState(() {
      _hits = hits;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _SearchField(
              controller: _typed,
              hasText: _hasText,
              onChanged: _typedSomething,
              onClear: () {
                _typed.clear();
                _find('');
              },
            ),
          ),
          if (_searching && _hits.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Expanded(
              child: _hits.isEmpty
                  ? Center(
                      child: Text(
                        _hasText ? 'Nothing like that' : 'Type to search',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: widget.scrollController,
                      itemCount: _hits.length,
                      separatorBuilder: (_, _) => const Divider(height: 0),
                      itemBuilder: (context, i) {
                        final hit = _hits[i];
                        return ListTile(
                          title: Text(hit.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            hit.address.join(', '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                          onTap: () => Navigator.of(context).pop(hit),
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.hasText,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool hasText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: 'Search a place',
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
          ),
          suffixIcon: hasText
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: onClear,
                )
              : null,
        ),
        onChanged: onChanged,
      );
}