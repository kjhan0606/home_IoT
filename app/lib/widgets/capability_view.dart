import 'package:flutter/material.dart';

import '../l10n/ko.dart';
import '../models/capability_spec.dart';
import '../models/device.dart';
import 'capabilities/appliances.dart';
import 'capabilities/curtain.dart';
import 'capabilities/generic.dart';
import 'capabilities/media.dart';
import 'capabilities/vacuum.dart';
import 'command.dart';

/// Display order for known capabilities; unknown ones follow alphabetically.
const capabilityOrder = [
  'power',
  'lock',
  'curtain',
  'washer',
  'dryer',
  'refrigeration',
  'vacuum',
  'vacuumMap',
  'roomCleaning',
  'zoneCleaning',
  'goTo',
  'fanSpeed',
  'mopping',
  'cleaningStats',
  'consumables',
  'volume',
  'channel',
  'mediaInput',
  'mediaPlayback',
  'launchApp',
  'brightness',
  'color',
  'sensor',
];

List<String> orderedCapabilities(Device d) {
  final keys = d.capabilities.keys.toList();
  int rank(String k) {
    final i = capabilityOrder.indexOf(k);
    return i < 0 ? capabilityOrder.length : i;
  }

  keys.sort((a, b) => rank(a) != rank(b) ? rank(a).compareTo(rank(b)) : a.compareTo(b));
  return keys;
}

/// Picks the widget for a capability from the hub's `uiHint` (never from the
/// device's brand). Falls back to the capability key for older hubs, then to
/// a generic card.
Widget capabilityWidget(Device device, CapabilityInstance inst, CapabilitySpec? spec) {
  final hint = spec?.uiHint ?? _defaultHints[inst.key] ?? 'generic';
  final hasMap = device.has('vacuumMap');
  switch (hint) {
    case 'curtain-controls':
      return CurtainCard(device: device, inst: inst);
    case 'toggle':
      return ToggleCard(device: device, inst: inst);
    case 'slider+mute':
      return VolumeCard(device: device, inst: inst);
    case 'stepper':
      return ChannelCard(device: device, inst: inst);
    case 'picker':
      return PickerCard(device: device, inst: inst, spec: spec);
    case 'transport':
      return TransportCard(device: device, inst: inst);
    case 'app-grid':
      return AppGridCard(device: device, inst: inst);
    case 'slider':
      return LevelSliderCard(device: device, inst: inst);
    case 'color-wheel':
      return ColorCard(device: device, inst: inst);
    case 'readout':
      return ReadoutCard(device: device, inst: inst);
    case 'laundry-cycle':
      return LaundryCard(device: device, inst: inst);
    case 'fridge-panel':
      return FridgeCard(device: device, inst: inst);
    case 'vacuum-controls':
      return VacuumControlsCard(device: device, inst: inst);
    case 'mop-controls':
      return MopCard(device: device, inst: inst);
    case 'consumables-list':
      return ConsumablesCard(device: device, inst: inst);
    case 'room-picker':
      return RoomPickerCard(device: device, inst: inst);
    case 'map-view':
      return MapEntryCard(device: device);
    case 'zone-drawer':
    case 'map-tap':
      // Both are used from the map screen; without a map they can't be used.
      return hasMap
          ? const SizedBox.shrink()
          : CapCard(title: Ko.cap(inst.key), child: const Text('이 기기는 지도를 제공하지 않아 사용할 수 없습니다.'));
    default:
      return GenericCapabilityCard(device: device, inst: inst, spec: spec);
  }
}

const _defaultHints = {
  'power': 'toggle',
  'lock': 'toggle',
  'curtain': 'curtain-controls',
  'volume': 'slider+mute',
  'channel': 'stepper',
  'mediaInput': 'picker',
  'fanSpeed': 'picker',
  'mediaPlayback': 'transport',
  'launchApp': 'app-grid',
  'brightness': 'slider',
  'color': 'color-wheel',
  'sensor': 'readout',
  'cleaningStats': 'readout',
  'washer': 'laundry-cycle',
  'dryer': 'laundry-cycle',
  'refrigeration': 'fridge-panel',
  'vacuum': 'vacuum-controls',
  'mopping': 'mop-controls',
  'consumables': 'consumables-list',
  'roomCleaning': 'room-picker',
  'vacuumMap': 'map-view',
  'zoneCleaning': 'zone-drawer',
  'goTo': 'map-tap',
};
