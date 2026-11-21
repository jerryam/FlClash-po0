import 'package:fl_clash/common/constant.dart';
import 'package:flutter/services.dart';

const _channel = EventChannel('$packageName/po0_screen');

/// Whether the screen is on: the current state first, then every change.
/// Checks pause while it is off, so the radio is not woken every few seconds.
Stream<bool> po0ScreenStates() =>
    _channel.receiveBroadcastStream().map((event) => event != false);
