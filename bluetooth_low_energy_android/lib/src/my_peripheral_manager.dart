import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy_platform_interface/bluetooth_low_energy_platform_interface.dart';

import 'jni.g.dart';
import 'my_api.dart';
import 'my_api.g.dart';
import 'my_central.dart';

base class MyPeripheralManager extends BasePeripheralManager
    implements MyPeripheralManagerFlutterAPI {
  final MyPeripheralManagerHostAPI _api;
  final StreamController<BluetoothLowEnergyStateChangedEventArgs>
      _stateChangedController;
  final StreamController<GATTCharacteristicReadEventArgs>
      _characteristicReadController;
  final StreamController<GATTCharacteristicWrittenEventArgs>
      _characteristicWrittenController;
  final StreamController<GATTCharacteristicNotifyStateChangedEventArgs>
      _characteristicNotifyStateChangedController;

  final Map<String, MyCentral> _centrals;
  final Map<int, Map<int, MutableGATTCharacteristic>> _characteristics;
  final Map<int, Map<int, MutableGATTDescriptor>> _descriptors;
  final Map<String, int> _mtus;
  final Map<String, Map<int, bool>> _confirms;
  final Map<String, MutableGATTCharacteristic> _preparedCharacteristics;
  final Map<String, MutableGATTDescriptor> _preparedDescriptors;
  final Map<String, List<int>> _preparedValue;

  BluetoothLowEnergyState _state;

  MyPeripheralManager()
      : _api = MyPeripheralManagerHostAPI(),
        _stateChangedController = StreamController.broadcast(),
        _characteristicReadController = StreamController.broadcast(),
        _characteristicWrittenController = StreamController.broadcast(),
        _characteristicNotifyStateChangedController =
            StreamController.broadcast(),
        _centrals = {},
        _characteristics = {},
        _descriptors = {},
        _mtus = {},
        _confirms = {},
        _preparedCharacteristics = {},
        _preparedDescriptors = {},
        _preparedValue = {},
        _state = BluetoothLowEnergyState.unknown;

  @override
  BluetoothLowEnergyState get state => _state;
  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      _stateChangedController.stream;
  @override
  Stream<GATTCharacteristicReadEventArgs> get characteristicRead =>
      _characteristicReadController.stream;
  @override
  Stream<GATTCharacteristicWrittenEventArgs> get characteristicWritten =>
      _characteristicWrittenController.stream;
  @override
  Stream<GATTCharacteristicNotifyStateChangedEventArgs>
      get characteristicNotifyStateChanged =>
          _characteristicNotifyStateChangedController.stream;

  @override
  void initialize() async {
    MyPeripheralManagerFlutterAPI.setUp(this);
    logger.info('initialize');
    await _api.initialize();
  }

  @override
  Future<void> addService(GATTService service) async {
    if (service is! MutableGATTService) {
      throw TypeError();
    }
    final characteristics = <int, MutableGATTCharacteristic>{};
    final descriptors = <int, MutableGATTDescriptor>{};
    final characteristicsArgs = <MyGattCharacteristicArgs>[];
    for (var characteristic in service.characteristics) {
      final descriptorsArgs = <MyGattDescriptorArgs>[];
      final properties = characteristic.properties;
      final canNotify =
          properties.contains(GATTCharacteristicProperty.notify) ||
              properties.contains(GATTCharacteristicProperty.indicate);
      if (canNotify) {
        // CLIENT_CHARACTERISTIC_CONFIG
        final cccDescriptor = MutableGATTDescriptor(
          uuid: UUID.short(0x2902),
          value: Uint8List.fromList([0x00, 0x00]),
        );
        final cccDescriptorArgs = cccDescriptor.toArgs();
        descriptorsArgs.add(cccDescriptorArgs);
        descriptors[cccDescriptorArgs.hashCodeArgs] = cccDescriptor;
      }
      for (var descriptor in characteristic.descriptors) {
        final descriptorArgs = descriptor.toArgs();
        descriptorsArgs.add(descriptorArgs);
        descriptors[descriptorArgs.hashCodeArgs] = descriptor;
      }
      final characteristicArgs = characteristic.toArgs(descriptorsArgs);
      characteristicsArgs.add(characteristicArgs);
      characteristics[characteristicArgs.hashCodeArgs] = characteristic;
    }
    final serviceArgs = service.toArgs(characteristicsArgs);
    logger.info('addService: $serviceArgs');
    await _api.addService(serviceArgs);
    _characteristics[serviceArgs.hashCodeArgs] = characteristics;
    _descriptors[serviceArgs.hashCodeArgs] = descriptors;
  }

  @override
  Future<void> removeService(GATTService service) async {
    final hashCodeArgs = service.hashCode;
    logger.info('removeService: $hashCodeArgs');
    await _api.removeService(hashCodeArgs);
    _characteristics.remove(hashCodeArgs);
    _descriptors.remove(hashCodeArgs);
  }

  @override
  Future<void> clearServices() async {
    logger.info('clearServices');
    await _api.clearServices();
    _characteristics.clear();
    _descriptors.clear();
  }

  @override
  Future<void> startAdvertising(Advertisement advertisement) async {
    final advertisementArgs = advertisement.toArgs();
    logger.info('startAdvertising: $advertisementArgs');
    await _api.startAdvertising(advertisementArgs);
  }

  @override
  Future<void> stopAdvertising() async {
    logger.info('stopAdvertising');
    await _api.stopAdvertising();
  }

  @override
  Future<Uint8List> readCharacteristic(GATTCharacteristic characteristic) {
    if (characteristic is! MutableGATTCharacteristic) {
      throw TypeError();
    }
    final hashCodeArgs = characteristic.hashCode;
    logger.info('readCharacteristic: $hashCodeArgs');
    final value = characteristic.value;
    return Future.value(value);
  }

  @override
  Future<void> writeCharacteristic(
    GATTCharacteristic characteristic, {
    required Uint8List value,
    Central? central,
  }) async {
    if (characteristic is! MutableGATTCharacteristic) {
      throw TypeError();
    }
    characteristic.value = value;
    if (central == null) {
      return;
    }
    if (central is! MyCentral) {
      throw TypeError();
    }
    final addressArgs = central.address;
    final hashCodeArgs = characteristic.hashCode;
    final confirm = _retrieveConfirm(addressArgs, hashCodeArgs);
    if (confirm == null) {
      logger.warning('The central is not listening.');
      return;
    }
    final trimmedValueArgs = characteristic.value;
    // Fragments the value by MTU - 3 size.
    // If mtu is null, use 23 as default MTU size.
    final mtu = _mtus[addressArgs] ?? 23;
    final fragmentSize = (mtu - 3).clamp(20, 512);
    var start = 0;
    while (start < trimmedValueArgs.length) {
      final end = start + fragmentSize;
      final fragmentedValueArgs = end < trimmedValueArgs.length
          ? trimmedValueArgs.sublist(start, end)
          : trimmedValueArgs.sublist(start);
      logger.info(
          'notifyCharacteristic: $hashCodeArgs - $fragmentedValueArgs, $confirm, $addressArgs');
      await _api.notifyCharacteristic(
        hashCodeArgs,
        fragmentedValueArgs,
        confirm,
        addressArgs,
      );
      start = end;
    }
  }

  @override
  void onStateChanged(int stateNumberArgs) {
    final stateArgs = MyBluetoothLowEnergyStateArgs.values[stateNumberArgs];
    logger.info('onStateChanged: $stateArgs');
    final state = stateArgs.toState();
    if (_state == state) {
      return;
    }
    _state = state;
    final eventArgs = BluetoothLowEnergyStateChangedEventArgs(state);
    _stateChangedController.add(eventArgs);
  }

  @override
  void onConnectionStateChanged(MyCentralArgs centralArgs, bool stateArgs) {
    final addressArgs = centralArgs.addressArgs;
    logger.info('onConnectionStateChanged: $addressArgs - $stateArgs');
    final central = centralArgs.toCentral();
    final state = stateArgs;
    if (state) {
      _centrals[addressArgs] = central;
    } else {
      _centrals.remove(addressArgs);
      _mtus.remove(addressArgs);
      _confirms.remove(addressArgs);
    }
  }

  @override
  void onMtuChanged(String addressArgs, int mtuArgs) {
    logger.info('onMtuChanged: $addressArgs - $mtuArgs');
    final mtu = mtuArgs;
    _mtus[addressArgs] = mtu;
  }

  @override
  void onCharacteristicReadRequest(
    String addressArgs,
    int hashCodeArgs,
    int idArgs,
    int offsetArgs,
  ) async {
    logger.info(
        'onCharacteristicReadRequest: $addressArgs.$hashCodeArgs - $idArgs, $offsetArgs');
    final central = _centrals[addressArgs];
    if (central == null) {
      return;
    }
    final characteristic = _retrieveCharacteristic(hashCodeArgs);
    if (characteristic == null) {
      return;
    }
    const statusArgs = BluetoothGatt.GATT_SUCCESS;
    final offset = offsetArgs;
    final valueArgs = _onCharacteristicRead(central, characteristic, offset);
    await _trySendResponse(
      addressArgs,
      idArgs,
      statusArgs,
      offsetArgs,
      valueArgs,
    );
  }

  @override
  void onCharacteristicWriteRequest(
    String addressArgs,
    int hashCodeArgs,
    int idArgs,
    int offsetArgs,
    Uint8List valueArgs,
    bool preparedWriteArgs,
    bool responseNeededArgs,
  ) async {
    logger.info(
        'onCharacteristicWriteRequest: $addressArgs.$hashCodeArgs - $idArgs, $offsetArgs, $valueArgs, $preparedWriteArgs, $responseNeededArgs');
    final central = _centrals[addressArgs];
    if (central == null) {
      return;
    }
    final characteristic = _retrieveCharacteristic(hashCodeArgs);
    if (characteristic == null) {
      return;
    }
    final int statusArgs;
    if (preparedWriteArgs) {
      final preparedCharacteristic = _preparedCharacteristics[addressArgs];
      if (preparedCharacteristic != null &&
          preparedCharacteristic != characteristic) {
        statusArgs = BluetoothGatt.GATT_CONNECTION_CONGESTED;
      } else {
        final preparedValueArgs = _preparedValue[addressArgs];
        if (preparedValueArgs == null) {
          _preparedCharacteristics[addressArgs] = characteristic;
          // Change the immutable Uint8List to mutable.
          _preparedValue[addressArgs] = [...valueArgs];
        } else {
          preparedValueArgs.insertAll(offsetArgs, valueArgs);
        }
        statusArgs = BluetoothGatt.GATT_SUCCESS;
      }
    } else {
      final value = valueArgs;
      _onCharacteristicWritten(central, characteristic, value);
      statusArgs = BluetoothGatt.GATT_SUCCESS;
    }
    if (responseNeededArgs) {
      await _trySendResponse(
        addressArgs,
        idArgs,
        statusArgs,
        offsetArgs,
        null,
      );
    }
  }

  @override
  void onCharacteristicNotifyStateChanged(
    String addressArgs,
    int hashCodeArgs,
    int stateNumberArgs,
  ) {
    final stateArgs =
        MyGattCharacteristicNotifyStateArgs.values[stateNumberArgs];
    logger.info(
        'onCharacteristicNotifyStateChanged: $addressArgs.$hashCodeArgs - $stateArgs');
    final central = _centrals[addressArgs];
    if (central == null) {
      return;
    }
    final characteristic = _retrieveCharacteristic(hashCodeArgs);
    if (characteristic == null) {
      return;
    }
    final state = stateArgs != MyGattCharacteristicNotifyStateArgs.none;
    final confirms = _confirms.putIfAbsent(addressArgs, () => {});
    if (state) {
      confirms[hashCodeArgs] =
          stateArgs == MyGattCharacteristicNotifyStateArgs.indicate;
    } else {
      confirms.remove(hashCodeArgs);
    }
    final eventArgs = GATTCharacteristicNotifyStateChangedEventArgs(
      central,
      characteristic,
      state,
    );
    _characteristicNotifyStateChangedController.add(eventArgs);
  }

  @override
  void onDescriptorReadRequest(
    String addressArgs,
    int hashCodeArgs,
    int idArgs,
    int offsetArgs,
  ) async {
    logger.info(
        'onDescriptorReadRequest: $addressArgs.$hashCodeArgs - $idArgs, $offsetArgs');
    final central = _centrals[addressArgs];
    if (central == null) {
      return;
    }
    final descriptor = _retrieveDescriptor(hashCodeArgs);
    if (descriptor == null) {
      return;
    }
    const statusArgs = BluetoothGatt.GATT_SUCCESS;
    final offset = offsetArgs;
    final valueArgs = descriptor.value.sublist(offset);
    await _trySendResponse(
      addressArgs,
      idArgs,
      statusArgs,
      offsetArgs,
      valueArgs,
    );
  }

  @override
  void onDescriptorWriteRequest(
    String addressArgs,
    int hashCodeArgs,
    int idArgs,
    int offsetArgs,
    Uint8List valueArgs,
    bool preparedWriteArgs,
    bool responseNeededArgs,
  ) async {
    logger.info(
        'onDescriptorWriteRequest: $addressArgs.$hashCodeArgs - $idArgs, $offsetArgs, $valueArgs, $preparedWriteArgs, $responseNeededArgs');
    final central = _centrals[addressArgs];
    if (central == null) {
      return;
    }
    final descriptor = _retrieveDescriptor(hashCodeArgs);
    if (descriptor == null) {
      return;
    }
    final int statusArgs;
    if (preparedWriteArgs) {
      final preparedDescriptor = _preparedDescriptors[addressArgs];
      if (preparedDescriptor != null && preparedDescriptor != descriptor) {
        statusArgs = BluetoothGatt.GATT_CONNECTION_CONGESTED;
      } else {
        final preparedValueArgs = _preparedValue[addressArgs];
        if (preparedValueArgs == null) {
          _preparedDescriptors[addressArgs] = descriptor;
          // Change the immutable Uint8List to mutable.
          _preparedValue[addressArgs] = [...valueArgs];
        } else {
          preparedValueArgs.insertAll(offsetArgs, valueArgs);
        }
        statusArgs = BluetoothGatt.GATT_SUCCESS;
      }
    } else {
      descriptor.value = valueArgs;
      statusArgs = BluetoothGatt.GATT_SUCCESS;
    }
    if (responseNeededArgs) {
      await _trySendResponse(
        addressArgs,
        idArgs,
        statusArgs,
        offsetArgs,
        null,
      );
    }
  }

  @override
  void onExecuteWrite(String addressArgs, int idArgs, bool executeArgs) async {
    logger.info('onExecuteWrite: $addressArgs - $idArgs, $executeArgs');
    final central = _centrals[addressArgs];
    final characteristic = _preparedCharacteristics.remove(addressArgs);
    final descriptor = _preparedDescriptors.remove(addressArgs);
    final elements = _preparedValue.remove(addressArgs);
    if (central == null || elements == null) {
      return;
    }
    final value = Uint8List.fromList(elements);
    final execute = executeArgs;
    if (execute) {
      if (characteristic == null && descriptor == null) {
        return;
      }
      if (characteristic != null) {
        _onCharacteristicWritten(central, characteristic, value);
      }
      if (descriptor != null) {
        descriptor.value = value;
      }
    }
    const statusArgs = BluetoothGatt.GATT_SUCCESS;
    await _trySendResponse(
      addressArgs,
      idArgs,
      statusArgs,
      0,
      null,
    );
  }

  MutableGATTCharacteristic? _retrieveCharacteristic(int hashCodeArgs) {
    final characteristics = _characteristics.values
        .reduce((value, element) => value..addAll(element));
    return characteristics[hashCodeArgs];
  }

  MutableGATTDescriptor? _retrieveDescriptor(int hashCodeArgs) {
    final descriptors =
        _descriptors.values.reduce((value, element) => value..addAll(element));
    return descriptors[hashCodeArgs];
  }

  bool? _retrieveConfirm(String addressArgs, int hashCodeArgs) {
    final confirms = _confirms[addressArgs];
    if (confirms == null) {
      return null;
    }
    return confirms[hashCodeArgs];
  }

  Future<void> _trySendResponse(
    String addressArgs,
    int idArgs,
    int statusArgs,
    int offsetArgs,
    Uint8List? valueArgs,
  ) async {
    try {
      _api.sendResponse(
        addressArgs,
        idArgs,
        statusArgs,
        offsetArgs,
        valueArgs,
      );
    } catch (e, stack) {
      logger.shout('Send response failed.', e, stack);
    }
  }

  Uint8List _onCharacteristicRead(
    MyCentral central,
    MutableGATTCharacteristic characteristic,
    int offset,
  ) {
    final value = characteristic.value;
    final trimmedValue = value.sublist(offset);
    if (offset == 0) {
      final eventArgs = GATTCharacteristicReadEventArgs(
        central,
        characteristic,
        value,
      );
      _characteristicReadController.add(eventArgs);
    }
    return trimmedValue;
  }

  void _onCharacteristicWritten(
    MyCentral central,
    MutableGATTCharacteristic characteristic,
    Uint8List value,
  ) async {
    characteristic.value = value;
    final trimmedValue = characteristic.value;
    final eventArgs = GATTCharacteristicWrittenEventArgs(
      central,
      characteristic,
      trimmedValue,
    );
    _characteristicWrittenController.add(eventArgs);
  }
}
