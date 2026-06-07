import 'package:flutter/material.dart';

class WSkeleton extends StatefulWidget {
  const WSkeleton({super.key});

  @override
  State<WSkeleton> createState() => WSkeletonItemS();
}

class WSkeletonItemS extends State<WSkeleton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.4, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(color: Colors.grey.shade300),
      ),
    );
  }
}
