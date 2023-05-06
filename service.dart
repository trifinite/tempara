import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:async/async.dart';
// import 'package:battery_plus/battery_plus.dart';
import 'package:beacons_plugin/beacons_plugin.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pedometer/pedometer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teslakee/database/db.dart';
import 'package:teslakee/main.dart';
import 'package:teslakee/protos/VCSEC.pb.dart';
import 'package:webcrypto/webcrypto.dart';

import './messages.dart';
import '../database/db-model.dart';
import '../helpers.dart';
import '../helpers/transport.dart';

class TeslaKeeService extends FlutterBackgroundServicePlatform {
  /// Registers this class as the default instance of [FlutterBackgroundServicePlatform].
  static void registerWith() {
    FlutterBackgroundServicePlatform.instance = TeslaKeeService();
  }

  bool _isFromInitialization = false;
  bool _isRunning = false;
  bool _isMainChannel = false;
  static const MethodChannel _backgroundChannel = const MethodChannel(
    'id.flutter/background_service_android_bg',
    JSONMethodCodec(),
  );

  static const MethodChannel _mainChannel = const MethodChannel(
    'id.flutter/background_service_android',
    JSONMethodCodec(),
  );

  bool _isWalking = false;
  bool _isFullOrCharging = false;
  bool _isVehicle = false;
  bool _isWifi = false;
  bool _isMobile = false;
  bool _isLocation = false;
  bool _bleConnected = false;

  //final _service = FlutterBackgroundService();
  StreamGroup _streams = StreamGroup();
  final _flutterReactiveBle = FlutterReactiveBle();
  final Connectivity _connectivity = Connectivity();
  late StreamController<String> _beaconEventsController =
      StreamController<String>.broadcast();

  final GeolocatorPlatform _geolocatorPlatform = GeolocatorPlatform.instance;
  Stream<Position> _positionStream = Geolocator.getPositionStream(
      locationSettings: LocationSettings()); // accuracy: LocationAccuracy.best

  String _newVehicleId = '';
  String _newVehicleVid = '';
  String _newVehicleVin = '';
  int _newVehicleMajor = 0;
  int _newVehicleMinor = 0;
  List<int> _newVehiclePublicKeyRaw = [];
  late EcdhPublicKey _newVehiclePublicKey;
  List<int> _newVehiclePhonePublicKeyRaw = [];
  late EcdhPrivateKey _newVehiclePhonePrivateKey;
  late EcdhPublicKey _newVehiclePhonePublicKey;
  List<int> _newVehiclePhoneKeyId = [];
  List<int> _newVehicleSharedKeyBytes = [];
  int _newVehicleKeyCount1 = 0;
  int _newVehicleKeyCount2 = 0;
  WhitelistInfo? _newVehicleWhitelistInfo;
  WhitelistEntryInfo? _newVehicleWhitelistEntry;
  Stream? _newVehicleConnection;
  int _newVehileTimeout = 60;
  int _discoveryTimeout = 5;
  Timer _newVehicleTimer = Timer(Duration(seconds: 0), () {});
  Timer _newVehicleProcessTimer = Timer(Duration(seconds: 0), () {});
  Timer _newVehicleTickleTimer = Timer(Duration(seconds: 0), () {});
  Timer _discoveryTimer = Timer(Duration(seconds: 0), () {});
  bool _newVehicleProcessWait = false;
  int _newVehicleProcessStep = 0;
  bool _newVehicleNfcConfirm = false;
  bool _newVehicleEnrolled = false;
  bool _newVehicleCardTapRequested = false;
  bool hasTest = false;
  int _beaconSignalThreshhold = -80;
  List<String> closebyVehicles = [];
  List<String> unlockedVehicles = [];
  List<String> connectedVehicles = [];

  Map<String, Vehicle> enrolledVehicles = Map();
  TeslaAccount? ta;
  late Stream<dynamic> _discovery;
  late SharedPreferences sprefs;

  String _onboardVehicleId = '';
  late Vehicle _obVehicle;

  Map<String, VehicleState> _managedVehicles = Map();
  Map<String, BluetoothBeacon> beacons = Map();

  String _currentUiVehicle = '00:00:00:00:00:00';
  Timer _pedometerTimer = Timer(Duration(seconds: 0), () {});
  int _pedometerTimeout = 10;
  Timer _batteryTimer = Timer(Duration(seconds: 0), () {});
  int _batteryTimeout = 60;
  Timer _vehicleTimeout = Timer(Duration(seconds: 0), () {});
  int _locationGracetime = 10;
  Timer _locationTimeout = Timer(Duration(seconds: 0), () {});

  Map<String, Uint8List> _receivedFragments = Map();

  void _updateVehicles() async {
    List<Vehicle> dbVehicles =
        await TeslaKeeDatabase.instance.readAllVehicles();
    dbVehicles.forEach((element) {
      String vin = element.vin;
      if (!enrolledVehicles.containsKey(vin)) {
        enrolledVehicles.putIfAbsent(vin, () => element);
      }
    });
    enrolledVehicles.forEach((key, value) {
      log((value as Vehicle).toJson().toString());
    });
  }

  void initialize() async {
    _updateNotification('Starting Service ', false);
    //_updateNotification(sprefs.getBool("sensors_wifi_enabled").toString(), false);

    ta = await TeslaKeeDatabase.instance.getTeslaAccount();
    log('SERVICE initializing');
    BeaconsPlugin.listenToBeacons(_beaconEventsController);
    await BeaconsPlugin.addRegion("TeslaVehicle", teslaUUID);
    BeaconsPlugin.addBeaconLayoutForAndroid(
        "m:2-3=0215,i:4-19,i:20-21,i:22-23,p:24-24");
    BeaconsPlugin.setBackgroundScanPeriodForAndroid(
        backgroundScanPeriod: 2200, backgroundBetweenScanPeriod: 10);
    BeaconsPlugin.startMonitoring();

    Timer.periodic(Duration(hours: 4), (timer) {
      if (ta != null) {
        // refresh token regularly
        // TODO
      }
    });

    _updateVehicles();

    _discovery = _flutterReactiveBle
        .scanForDevices(withServices: [], scanMode: ScanMode.lowLatency);

    _flutterReactiveBle.initialize();
    _streams.add(_beaconEventsController.stream);
    _streams.add(Pedometer.pedestrianStatusStream);
    _streams.add(Pedometer.stepCountStream);
//    _streams.add(Battery().onBatteryStateChanged);
    _streams.add(_connectivity.onConnectivityChanged);
    _streams.add(_positionStream);
    _streams.add(_flutterReactiveBle.statusStream);
    _streams.add(_flutterReactiveBle.characteristicValueStream);
    _streams.add(_flutterReactiveBle.connectedDeviceStream);
    _streams.add(_streamController.stream);

    _streams.stream.listen((event) => _handleEvent(event), onError: (event) {
      log("ERROR: " + event.runtimeType.toString(),
          time: DateTime.now(), level: 3);
    });
  }

  TeslaKeeService() {
    initialize();
  }

  void setupAsMain() {
    _isFromInitialization = true;
    _isRunning = true;
    _isMainChannel = true;
    _mainChannel.setMethodCallHandler(_handle);
  }

  void setupAsBackground() {
    _isRunning = true;
    _backgroundChannel.setMethodCallHandler(_handle);
  }

  // background process communication
  Future<dynamic> _handle(MethodCall call) async {
    print("XXX EVENT RECEIVED: " + call.toString());

    switch (call.method) {
      case "onReceiveData":
        if ((call.arguments["addVehicle"] != null) &&
            (call.arguments["addVehicle"].toString().length > 0)) {
          _addNewVehicle(call.arguments["addVehicle"]);
        } else if ((call.arguments["buttonUnlockCar"] != null) &&
            (call.arguments["buttonUnlockCar"].toString().length > 0)) {
          Vehicle? vehicle =
              _getEnrolledVehicleByVin(call.arguments["buttonUnlockCar"]);
          if (vehicle != null) {
            if (unlockedVehicles.join("::").contains(vehicle.vin)) {
              _sendToVehicle(
                  vehicle.btAddress,
                  await getSignedMessage(
                      base64Decode(vehicle.crKeyId),
                      vehicle.getCounter(),
                      base64Decode(vehicle.crShared),
                      await getAction(RKEAction_E.RKE_ACTION_LOCK)));
            } else {
              _sendToVehicle(
                  vehicle.btAddress,
                  await getSignedMessage(
                      base64Decode(vehicle.crKeyId),
                      vehicle.getCounter(),
                      base64Decode(vehicle.crShared),
                      await getAction(RKEAction_E.RKE_ACTION_UNLOCK)));
            }
          }
        } else if ((call.arguments["buttonOpenChargeport"] != null) &&
            (call.arguments["buttonOpenChargeport"].toString().length > 0)) {
          Vehicle? vehicle =
              _getEnrolledVehicleByVin(call.arguments["buttonOpenChargeport"]);
          if (vehicle != null) {
            _sendToVehicle(
                vehicle.btAddress,
                await getSignedMessage(
                    base64Decode(vehicle.crKeyId),
                    vehicle.getCounter(),
                    base64Decode(vehicle.crShared),
                    await getAction(RKEAction_E.RKE_ACTION_OPEN_CHARGE_PORT)));
          }
        } else if ((call.arguments["buttonLockSafe"] != null) &&
            (call.arguments["buttonLockSafe"].toString().length > 0)) {
          Vehicle? vehicle =
              _getEnrolledVehicleByVin(call.arguments["buttonLockSafe"]);
          if (vehicle != null) {
            _sendToVehicle(
                vehicle.btAddress,
                await getSignedMessage(
                    base64Decode(vehicle.crKeyId),
                    vehicle.getCounter(),
                    base64Decode(vehicle.crShared),
                    await getAction(RKEAction_E.RKE_ACTION_LOCK)));
          }
        } else if ((call.arguments["buttonOpenFrunk"] != null) &&
            (call.arguments["buttonOpenFrunk"].toString().length > 0)) {
          Vehicle? vehicle =
              _getEnrolledVehicleByVin(call.arguments["buttonOpenFrunk"]);
          if (vehicle != null) {
            _sendToVehicle(
                vehicle.btAddress,
                await getSignedMessage(
                    base64Decode(vehicle.crKeyId),
                    vehicle.getCounter(),
                    base64Decode(vehicle.crShared),
                    await getAction(RKEAction_E.RKE_ACTION_OPEN_FRUNK)));
          }
        } else if ((call.arguments["buttonOpenTrunk"] != null) &&
            (call.arguments["buttonOpenTrunk"].toString().length > 0)) {
          Vehicle? vehicle =
              _getEnrolledVehicleByVin(call.arguments["buttonOpenTrunk"]);
          if (vehicle != null) {
            _sendToVehicle(
                vehicle.btAddress,
                await getSignedMessage(
                    base64Decode(vehicle.crKeyId),
                    vehicle.getCounter(),
                    base64Decode(vehicle.crShared),
                    await getAction(RKEAction_E.RKE_ACTION_OPEN_TRUNK)));
          }
        } else if ((call.arguments["action"] != null) &&
            (call.arguments["action"].toString().length > 0)) {
          log("XXX action");
          if (call.arguments["action"].toString().compareTo("requestUpdate") ==
              0) {
            _sendUiUpdates();
          }
        }
        break;
      default:
        print("XXX EVENT RECEIVED: " + call.arguments.toString());
      // Map<String, dynamic> command = jsonDecode(call.arguments.toString());
      // if (call.arguments.toString().contains("addVehicle")) {
      //   print("XXX EVENT RECEIVED: "+call.arguments.toString());
      //   _addNewVehicle(command["addVehicle"]);
      //}
    }
    return true;
  }

  Future<bool> start() async {
    if (!_isMainChannel) {
      throw Exception(
          'This method only allowed from UI. Please call configure() first.');
    }

    final result = await _mainChannel.invokeMethod('start');
    return result ?? false;
  }

  Future<bool> configure({
    required IosConfiguration iosConfiguration,
    required AndroidConfiguration androidConfiguration,
  }) async {
    final CallbackHandle? handle =
        PluginUtilities.getCallbackHandle(androidConfiguration.onStart);
    if (handle == null) {
      return false;
    }

    setupAsMain();
    final result = await _mainChannel.invokeMethod(
      "configure",
      {
        "handle": handle.toRawHandle(),
        "is_foreground_mode": androidConfiguration.isForegroundMode,
        "auto_start_on_boot": androidConfiguration.autoStart,
      },
    );

    return result ?? false;
  }

  // Send data from UI to Service, or from Service to UI
  void sendData(Map<String, dynamic> data) async {
    if (!(await (isServiceRunning()))) {
      dispose();
      return;
    }

    if (_isFromInitialization) {
      _mainChannel.invokeMethod("sendData", data);
      return;
    }

    _backgroundChannel.invokeMethod("sendData", data);
  }

  // Set Foreground Notification Information
  // Only available when foreground mode is true
  void setNotificationInfo({String? title, String? content}) {
    if (Platform.isAndroid)
      _backgroundChannel.invokeMethod("setNotificationInfo", {
        "title": title,
        "content": content,
      });
  }

  // Set Foreground Mode
  // Only for Android
  void setForegroundMode(bool value) {
    if (Platform.isAndroid)
      _backgroundChannel.invokeMethod("setForegroundMode", {
        "value": value,
      });
  }

  Future<bool> isServiceRunning() async {
    if (_isMainChannel) {
      var result = await _mainChannel.invokeMethod("isServiceRunning");
      return result ?? false;
    } else {
      return _isRunning;
    }
  }

  // StopBackgroundService from Running
  void stopBackgroundService() {
    _backgroundChannel.invokeMethod("stopService");
    _isRunning = false;
  }

  void setAutoStartOnBootMode(bool value) {
    if (Platform.isAndroid)
      _backgroundChannel.invokeMethod("setAutoStartOnBootMode", {
        "value": value,
      });
  }

  StreamController<Map<String, dynamic>?> _streamController =
      StreamController.broadcast();

  Stream<Map<String, dynamic>?> get onDataReceived => _streamController.stream;

  void dispose() {
    _streamController.close();
  }

  // Methods used while adding new vehicle

  Future<String> _getVinIdentifier(String vin) async {
    var result = await Hash.sha1.digestBytes(utf8.encode(vin));
    return "S" + _toHexString(result, 0).substring(0, 16);
  }

  void _cancelDiscovery() {
    _streams.remove(_discovery);
    if (_discoveryTimer.isActive) {
      _discoveryTimer.cancel();
    }
  }

  void _extractManufacturerDetails(Uint8List manufacturerData) {
    _newVehicleMajor = ((manufacturerData[20] << 8) + manufacturerData[21]);
    _newVehicleMinor = ((manufacturerData[22] << 8) + manufacturerData[23]);
  }

  void _addNewVehicle(String vin) async {
    log("_addVehicle called!");
    // start Timer
    _discoveryTimer = Timer(Duration(seconds: _discoveryTimeout), () {
      _cancelDiscovery();
    });

    // Generate a keypair.
    JsonWebKeyPair keyPair = await _generateKeyPair();
    _newVehiclePhonePrivateKey = await EcdhPrivateKey.importJsonWebKey(
        json.decode(keyPair.privateKey), EllipticCurve.p256);
    _newVehiclePhonePublicKey = await EcdhPublicKey.importJsonWebKey(
        json.decode(keyPair.publicKey), EllipticCurve.p256);
    _newVehiclePhonePublicKeyRaw =
        await _newVehiclePhonePublicKey.exportRawKey();
    _newVehiclePhoneKeyId = await _generateKeyId(_newVehiclePhonePublicKeyRaw);

    // starting discovery

    _newVehicleVin = vin;
    _newVehicleVid = await _getVinIdentifier(vin);
    //print("IDENTIFIER: "+_newVehicleVid);
    try {
      _streams.add(_discovery);
    } catch (e) {
      // print(e);
    }
  }

  void _advanceNewVehicleProcess([FromVCSECMessage? message]) async {
    if (_newVehicleTickleTimer.isActive) _newVehicleTickleTimer.cancel();
    if (!_newVehicleEnrolled) {
      if (message != null) {
        if (message.hasWhitelistInfo()) {
          if (_newVehicleKeyCount1 == 0) {
            _newVehicleKeyCount1 = message.whitelistInfo.numberOfEntries;
            if (_newVehicleProcessTimer.isActive)
              _newVehicleProcessTimer.cancel();
            _newVehicleProcessWait = false;
          } else if (_newVehicleKeyCount2 == 0) {
            _newVehicleKeyCount2 = message.whitelistInfo.numberOfEntries;
            if (_newVehicleProcessTimer.isActive)
              _newVehicleProcessTimer.cancel();
            _newVehicleProcessWait = false;
          }
        } else if (message.hasSessionInfo()) {
          if ((message.sessionInfo.hasPublicKey()) &&
              (_newVehiclePublicKeyRaw.length == 0)) {
            _newVehiclePublicKeyRaw = message.sessionInfo.publicKey;
            if (_newVehicleProcessTimer.isActive)
              _newVehicleProcessTimer.cancel();
            _newVehicleProcessWait = false;
          }
        } else if (message.hasWhitelistEntryInfo()) {
          _newVehicleWhitelistEntry = message.whitelistEntryInfo;
          if (_newVehicleProcessTimer.isActive)
            _newVehicleProcessTimer.cancel();
          _newVehicleProcessWait = false;
        } else if (message.hasCommandStatus()) {
          if ((message.commandStatus.hasWhitelistOperationStatus()) &&
              (message.commandStatus.whitelistOperationStatus
                  .hasSignerOfOperation())) {
            _newVehicleNfcConfirm = true;
            if (_newVehicleProcessTimer.isActive)
              _newVehicleProcessTimer.cancel();
            _newVehicleProcessWait = false;
            sendData({'AD_Dismiss': 'true'});
          }
          switch (message.commandStatus.operationStatus) {
            case OperationStatus_E.OPERATIONSTATUS_WAIT:
              if (!_newVehicleCardTapRequested) {
                sendData({'AD_RequestCardTap': 'true'});
                _newVehicleCardTapRequested = true;
              }
              break;
            case OperationStatus_E.OPERATIONSTATUS_ERROR:
              _newVehicleNfcConfirm = false;
              if (_newVehicleProcessTimer.isActive)
                _newVehicleProcessTimer.cancel();
              _newVehicleProcessWait = false;
              break;
            default:
              break;
          }
        }
      }
      if (!_newVehicleProcessWait) {
        if (_newVehiclePublicKeyRaw.length == 0) {
          _newVehicleProcessStep = 0;
        } else if (_newVehicleKeyCount1 == 0) {
          _newVehicleProcessStep = 1;
        } else if (!_newVehicleNfcConfirm) {
          _newVehicleProcessStep = 2;
        } else if (_newVehicleKeyCount2 == 0) {
          _newVehicleProcessStep = 3;
        } else if (_newVehicleWhitelistEntry == null) {
          _newVehicleProcessStep = 4;
        } else if (_newVehicleKeyCount1 == _newVehicleKeyCount2) {
          _newVehicleKeyCount2 = 0;
          _newVehicleNfcConfirm = false;
          _newVehicleProcessStep = 2;
        } else if ((_newVehicleWhitelistEntry != null) &&
            (_newVehicleWhitelistEntry!.hasKeyId())) {
          List<int> receivedKeyId =
              _newVehicleWhitelistEntry!.keyId.publicKeySHA1;
          if (base64Encode(receivedKeyId) ==
              base64Encode(_newVehiclePhoneKeyId)) _newVehicleEnrolled = true;
        }
      }
    }

    if ((!_newVehicleEnrolled) && (!_newVehicleProcessWait)) {
      switch (_newVehicleProcessStep) {
        case 0:
          _newVehicleProcessWait = true;
          _newVehicleProcessTimer = Timer(Duration(seconds: 3), () {
            _newVehicleProcessWait = false;
          });
          _sendToVehicle(
              _newVehicleId, requestEphemeralKey(_newVehiclePhoneKeyId));
          break;
        case 1:
          _newVehicleProcessWait = true;
          _newVehicleProcessTimer = Timer(Duration(seconds: 3), () {
            _newVehicleProcessWait = false;
          });
          _sendToVehicle(
              _newVehicleId, requestWhitelistInfo(_newVehiclePhoneKeyId));

          break;
        case 2:
          _newVehicleProcessWait = true;
          _newVehicleProcessTimer = Timer(Duration(seconds: 3), () {
            _newVehicleProcessWait = false;
          });
          _sendToVehicle(_newVehicleId,
              requestKeyWhitelisting(_newVehiclePhonePublicKeyRaw));
          break;
        case 3:
          _newVehicleProcessWait = true;
          _newVehicleProcessTimer = Timer(Duration(seconds: 3), () {
            _newVehicleProcessWait = false;
          });
          _sendToVehicle(
              _newVehicleId, requestWhitelistInfo(_newVehiclePhoneKeyId));
          break;
        case 4:
          _newVehicleProcessWait = true;
          _newVehicleProcessTimer = Timer(Duration(seconds: 3), () {
            _newVehicleProcessWait = false;
          });
          _sendToVehicle(
              _newVehicleId, requestWhitelistEntryInfo(_newVehiclePhoneKeyId));
          break;
      }
    } else if (_newVehicleEnrolled) {
      if (_newVehicleProcessTimer.isActive) _newVehicleProcessTimer.cancel();
      _newVehicleProcessWait = false;
      _cancelNewVehicle();
    }
  }

  void _cancelNewVehicle() async {
    if (_newVehicleTimer.isActive) _newVehicleTimer.cancel();

    if (_newVehicleEnrolled) {
      _newVehiclePublicKey = await EcdhPublicKey.importRawKey(
          _newVehiclePublicKeyRaw, EllipticCurve.p256);
      Uint8List derivedBits = await _newVehiclePhonePrivateKey.deriveBits(
          256, _newVehiclePublicKey);
      AesGcmSecretKey aesGcmSecretKey =
          await AesGcmSecretKey.importRawKey(derivedBits);

      Uint8List sha1DerivedBits = await Hash.sha1.digestBytes(await aesGcmSecretKey
          .exportRawKey()); //https://gist.github.com/pinkeshdarji/83f1d0281eb9f3be500649a37370ae35
      _newVehicleSharedKeyBytes = sha1DerivedBits.sublist(0, 16);

      // TODO - create Vehicle from existing teslaaccountvehicle by VIN

      TeslaAccountVehicle vehicle = await TeslaKeeDatabase.instance
          .readTeslaAccountVehicle(_newVehicleVin);

      var newVehile = Vehicle(
        btAddress: _newVehicleId,
        btMajor: _newVehicleMajor,
        btMinor: _newVehicleMinor,
        btName: _newVehicleVid,
        btTxPower: 0,
        crCounter: 2,
        crKeyId: base64Encode(_newVehiclePhoneKeyId),
        crShared: base64Encode(_newVehicleSharedKeyBytes),
        crPrivKey: base64Encode(
            jsonEncode(await _newVehiclePhonePrivateKey.exportJsonWebKey())
                .codeUnits),
        crPubKey: base64Encode(
            jsonEncode(await _newVehiclePhonePublicKey.exportJsonWebKey())
                .codeUnits),
        pubKey: base64Encode(
            jsonEncode(await _newVehiclePublicKey.exportJsonWebKey())
                .codeUnits),
        uiColor: getRGBfromColor(getPaintFromOptions(vehicle.optionCodes)),
        uiPosition: 0,
        vin: _newVehicleVin,
        name: vehicle.displayName,
        type: vehicle.vin.substring(3, 4),
        created: DateTime.now(),
        lastChange: DateTime.now(),
        whitelistId: 0,
      );
      TeslaKeeDatabase.instance.createVehicle(newVehile);
      // send success
      sendData({'AD_Success': 'true'});
      _updateNotification('Success', false);
    } else {
      // send failure
      sendData({'AD_Failure': 'true'});
      _updateNotification('Failure', false);
    }

    _streams.remove(_discovery);

    // Tidy up
    _newVehicleId = '';
    _newVehicleVid = '';
    _newVehicleVin = '';
    _newVehicleMajor = 0;
    _newVehicleMinor = 0;
    _newVehiclePublicKeyRaw = [];
    _newVehiclePhonePublicKeyRaw = [];
    _newVehiclePhoneKeyId = [];
    _newVehicleKeyCount1 = 0;
    _newVehicleKeyCount2 = 0;
    //_newVehicleWhitelistInfo;
    _newVehicleProcessWait = false;
    _newVehicleEnrolled = false;
  }

  Future<JsonWebKeyPair> _generateKeyPair() async {
    // final keyPair = await EcdhPrivateKey.generateKey(EllipticCurve.p256);
    // final publicKeyJwk = await keyPair.publicKey.exportJsonWebKey();
    // final privateKeyJwk = await keyPair.privateKey.exportJsonWebKey();
    final keyPair = await EcdhPrivateKey.generateKey(EllipticCurve.p256);
    final publicKeyJwk2 = await keyPair.publicKey.exportJsonWebKey();
    final privateKeyJwk2 = await keyPair.privateKey.exportJsonWebKey();


    final publicKeyJwk = json.decode('{"kty": "EC","crv": "P-256","x": "8gR3hgLo37HyiVB9cI0EeLdisoNZy8x1KS_AR3KhZEo","y": "mvuttC5fQHVr6O-LDgygvUAkbgh6y61UQ5avlq9kDWw"}');
    final privateKeyJwk = json.decode('{"kty": "EC","crv": "P-256","x": "8gR3hgLo37HyiVB9cI0EeLdisoNZy8x1KS_AR3KhZEo","y": "mvuttC5fQHVr6O-LDgygvUAkbgh6y61UQ5avlq9kDWw","d": "OlnotXCjwnxuxkNM3WlObe3OvrcuZB3gSbvjPHdpyXs"}');

    log(publicKeyJwk.toString());
    log(publicKeyJwk2.toString());


    return JsonWebKeyPair(
      privateKey: json.encode(privateKeyJwk),
      publicKey: json.encode(publicKeyJwk),
    );
  }

  Future<List<int>> _generateKeyId(List<int> pubKey) async {
    Uint8List shaPub = await Hash.sha1.digestBytes(pubKey);
    return shaPub.sublist(0, 4);
  }

  void _sendUiUpdates() async {
    sendData({SMSG_SENSOR: _isWifi ? SVAL_WIFION : SVAL_WIFIOFF});
    sendData({SMSG_SENSOR: _isMobile ? SVAL_MOBILEON : SVAL_MOBILEOFF});
    sendData({SMSG_SENSOR: _isWalking ? SVAL_PEDOON : SVAL_PEDOOFF});
    sendData({SMSG_SENSOR: _isLocation ? SVAL_LOCAON : SVAL_LOCAOFF});
    sendData({SMSG_SENSOR: _isFullOrCharging ? SVAL_CHARGEON : SVAL_CHARGEOFF});
    if (_bleConnected) {
      sendData({'connectedVehicles': connectedVehicles.join("::")});
    } else if (!_bleConnected) {
      sendData({'connectedVehicles': ' '});
    }
  }

  void _updateNotification(String notificationText, bool audio) async {
    // if (audio) FlutterBeep.beep();
    setNotificationInfo(
      title: 'TeslaKee',
      content: notificationText,
    );
    sendData({'debugMessage': notificationText});
  }

  void _updatePedometerStatus(PedestrianStatus event) async {
    if ((event).status.toLowerCase() == 'walking') {
      if (_pedometerTimer.isActive) _pedometerTimer.cancel();
      _isWalking = true;
      sendData({SMSG_SENSOR: SVAL_PEDOON});
    } else if ((event).status.toLowerCase() == 'stopped') {
      sendData({SMSG_SENSOR: SVAL_PEDOWAIT});
      _pedometerTimer = Timer(Duration(seconds: 10), () {
        _isWalking = false;
        sendData({SMSG_SENSOR: SVAL_PEDOOFF});
      });
    }
  }

  void _updateConnectionStatus(ConnectionStateUpdate event) async {
    if (_managedVehicles[event.deviceId] != null) {
      switch (event.connectionState) {
        case DeviceConnectionState.connecting:
          _managedVehicles[event.deviceId]!.isConnected = false;
          _managedVehicles[event.deviceId]!.isActive = false;
          _managedVehicles[event.deviceId]!.isChangingConnection = true;
          break;
        case DeviceConnectionState.connected:
          _managedVehicles[event.deviceId]!.isConnected = true;
          _managedVehicles[event.deviceId]!.isActive = false;
          _managedVehicles[event.deviceId]!.isChangingConnection = false;
          break;
        case DeviceConnectionState.disconnecting:
          _managedVehicles[event.deviceId]!.isConnected = false;
          _managedVehicles[event.deviceId]!.isActive = false;
          _managedVehicles[event.deviceId]!.isChangingConnection = true;
          break;
        case DeviceConnectionState.disconnected:
          _managedVehicles[event.deviceId]!.isConnected = false;
          _managedVehicles[event.deviceId]!.isActive = false;
          _managedVehicles[event.deviceId]!.isChangingConnection = false;
          break;
      }
    }
  }

  // void _updateBatteryStatus(BatteryState event) async {
  //   if ((event == BatteryState.charging) || (event == BatteryState.full)) {
  //     _isFullOrCharging = true;
  //     sendData({SMSG_SENSOR: SVAL_CHARGEON});
  //     if (_batteryTimer.isActive) _batteryTimer.cancel();
  //     _batteryTimer = Timer(Duration(seconds: _batteryTimeout), () {
  //       _isFullOrCharging = false;
  //       sendData({SMSG_SENSOR: SVAL_CHARGEOFF});
  //     });
  //   }
  // }

  void _updateLocationStatus(Position event) async {
    if (!event.isMocked) {
      _isLocation = true;
      sendData({SMSG_SENSOR: SVAL_LOCAON});
      if (_locationTimeout.isActive) _locationTimeout.cancel();
      _locationTimeout = Timer(Duration(seconds: _locationGracetime), () {
        _isLocation = false;
        sendData({SMSG_SENSOR: SVAL_LOCAOFF});
      });
    }
    _isLocation = true;
    sendData({SMSG_SENSOR: SVAL_LOCAON});
  }

  void _updateBeaconStatus(BeaconResult event) async {
    if (true) {
      //  (event.rssi > _beaconSignalThreshhold) {
      if (_vehicleTimeout.isActive) _vehicleTimeout.cancel();
      closebyVehicles = [];
      enrolledVehicles.forEach((key, value) {
        _isVehicle = false;
        if ((value.btMajor == event.major) && (value.btMajor == event.major)) {
          closebyVehicles.add(value.vin); // vin is used in front- and backend
          _isVehicle = true;
        }
        sendData({'closebyVehicles': closebyVehicles.join("::")});
      });
      //
      // if (!_currentUiVehicle.contains('80:6F:B0:26:3C:2A')) {
      //   sendData({'activeVehicle': '80:6F:B0:26:3C:2A'});
      // }

      // NORMAL
      // _connectVehicle(event.macAddress);

      sendData({SMSG_SENSOR: SVAL_VEHICLEON});
      if (_vehicleTimeout.isActive) _vehicleTimeout.cancel();
      _vehicleTimeout = Timer(Duration(seconds: 1), () {
        _isVehicle = false;
        sendData({'closebyVehicles': ' '});
        sendData({SMSG_SENSOR: SVAL_VEHICLEOFF});
      });
    } else {
      sendData({'dismissAppDialog': 'true'});
    }
    _checkConnect();
  }

  void _checkConnect() {
    closebyVehicles.forEach((element) {
      enrolledVehicles.forEach((key, value) {
        if (value.vin.contains(element)) {
          _connectVehicle(value.btAddress);
        }
      });
    });
  }

  void _connectNewVehicle(String deviceId) async {
    _newVehicleId = deviceId;
    // start _newVehicleTimer
    _newVehicleTimer = Timer(Duration(seconds: _newVehileTimeout), () {
      _cancelNewVehicle();
    });

    _flutterReactiveBle
        .connectToAdvertisingDevice(
      id: deviceId,
      withServices: [],
      // Uuid.parse(teslaServiceUUID)
      prescanDuration: const Duration(seconds: 5),
      //servicesWithCharacteristicsToDiscover: {Uuid.parse(teslaServiceUUID): [Uuid.parse(teslaCharacteristicFromVehicleUUID), Uuid.parse(teslaCharacteristicToVehicleUUID)]},
      connectionTimeout: const Duration(seconds: 2),
    )
        .listen((connectionState) {
      // Handle connection state updates
    }, onError: (dynamic error) {
      // Handle a possible error
    });
  }

  void _connectVehicle(String id) async {
    _flutterReactiveBle
        .connectToDevice(id: id)
        .listen((event) {}, onError: (error) {});
  }

  void _unsubscribeCharacteristic(String id) async {
    _streams.remove(_flutterReactiveBle.subscribeToCharacteristic(
        QualifiedCharacteristic(
            characteristicId: Uuid.parse(teslaCharacteristicFromVehicleUUID),
            serviceId: Uuid.parse(teslaServiceUUID),
            deviceId: id)));
    await _flutterReactiveBle.requestMtu(deviceId: id, mtu: 512);

    _bleConnected = false;
  }

  void _subscribeCharacteristic(String id) async {
    _streams.add(_flutterReactiveBle.subscribeToCharacteristic(
        QualifiedCharacteristic(
            characteristicId: Uuid.parse(teslaCharacteristicFromVehicleUUID),
            serviceId: Uuid.parse(teslaServiceUUID),
            deviceId: id)));
    await _flutterReactiveBle.requestMtu(deviceId: id, mtu: 512);
    connectedVehicles.add(id);
    _bleConnected = true;
    _sendUiUpdates();
    Vehicle? vehicle = _getEnrolledVehicleByAddress(id);
    if (vehicle != null) {
      _sendToVehicle(
          id, await sendInformationRequest(base64Decode(vehicle.crKeyId)));
    }
  }

  void _getWhitelistInfo(String id) async {
    ToVCSECMessage unsignedMessage = ToVCSECMessage(
        unsignedMessage: UnsignedMessage(
      informationRequest: InformationRequest(
          informationRequestType: InformationRequestType
              .INFORMATION_REQUEST_TYPE_GET_WHITELIST_INFO),
    ));
    Uint8List message = unsignedMessage.writeToBuffer();
    _sendToVehicle(id, message);
  }

  void _getVehicleInfo(String id) async {
    ToVCSECMessage unsignedMessage = ToVCSECMessage(
        unsignedMessage: UnsignedMessage(
      informationRequest: InformationRequest(
          informationRequestType:
              InformationRequestType.INFORMATION_REQUEST_TYPE_GET_VEHICLE_INFO),
    ));
    Uint8List message = unsignedMessage.writeToBuffer();
    _sendToVehicle(id, message);
  }

  void _getEphemeralPublicKey(String id) async {
    ToVCSECMessage unsignedMessage = ToVCSECMessage(
        unsignedMessage: UnsignedMessage(
      informationRequest: InformationRequest(
          informationRequestType: InformationRequestType
              .INFORMATION_REQUEST_TYPE_GET_EPHEMERAL_PUBLIC_KEY),
    ));
    Uint8List message = unsignedMessage.writeToBuffer();
    _sendToVehicle(id, message);
  }

  void _getTest(String id) async {
    ToVCSECMessage unsignedMessage = ToVCSECMessage(
        unsignedMessage: UnsignedMessage(
      informationRequest: InformationRequest(
          informationRequestType:
              InformationRequestType.INFORMATION_REQUEST_TYPE_GET_TOKEN),
    ));
    Uint8List message = unsignedMessage.writeToBuffer();
    _sendToVehicle(id, message);
  }

  void _openChargePort(String id) async {
    ToVCSECMessage unsignedMessage = ToVCSECMessage(
        unsignedMessage: UnsignedMessage(
            rKEAction: RKEAction_E.RKE_ACTION_OPEN_CHARGE_PORT));
    Uint8List message = unsignedMessage.writeToBuffer();
    _sendToVehicle(id, message);
  }

  void _getStatus(String id) async {
    ToVCSECMessage unsignedMessage = ToVCSECMessage(
        unsignedMessage: UnsignedMessage(
      informationRequest: InformationRequest(
          informationRequestType:
              InformationRequestType.INFORMATION_REQUEST_TYPE_GET_STATUS),
    ));
    Uint8List message = unsignedMessage.writeToBuffer();
    _sendToVehicle(id, message);
  }

  _sendToVehicle(String id, Uint8List message) {
    int len = message.lengthInBytes;
    List<int> temp = message.toList();
    List<int> prefixed = [len >> 8, len];
    prefixed.addAll(temp);
    Uint8List prefixedMessage = Uint8List.fromList(prefixed);
    log("Sending prefixed Message " + _toHexString(prefixedMessage, 0));
    _flutterReactiveBle.writeCharacteristicWithResponse(
        QualifiedCharacteristic(
            characteristicId: Uuid.parse(teslaCharacteristicToVehicleUUID),
            serviceId: Uuid.parse(teslaServiceUUID),
            deviceId: id),
        value: prefixedMessage);
  }

  String _toHexString(Uint8List bytes, int offset) {
    String retVal = "";

    for (int i = 0; i < bytes.lengthInBytes; i++) {
      if (i >= offset)
        retVal = retVal + bytes[i].toRadixString(16).padLeft(2, '0');
    }
    return retVal;
  }

  void _handleEvent(dynamic event) async {
    //print("HANDLE EVENT CALLED " + event.toString());
    if (event.runtimeType == DiscoveredDevice) {
      String manufacturerData =
          _toHexString((event as DiscoveredDevice).manufacturerData, 0);
      String deviceName = (event).name;
      String deviceId = (event).id;

      if ((deviceName.length == 18) && (deviceName.startsWith("S"))) {
        // (manufacturerData.length==50) &&
        if ((_discoveryTimer.isActive) &&
            (deviceName.startsWith(_newVehicleVid))) {
          // !(_newVehicleTimer.isActive) &&
          print("NEW VEHICLE: " +
              (event).name +
              " " +
              manufacturerData.length.toString());
          _extractManufacturerDetails((event).manufacturerData);
          _cancelDiscovery();
          _connectNewVehicle(deviceId);
        } else {
          print("DISCOVERED VEHICLE: " +
              (event).name +
              " " +
              (event).rssi.toString() +
              " " +
              _toHexString((event).manufacturerData, 0));
        }
      }
    } else if (event.runtimeType == PedestrianStatus) {
      print("PEDO " + (event as PedestrianStatus).status.toString());
      _updatePedometerStatus(event);
    } else if (event.runtimeType == ConnectivityResult) {
      switch (event as ConnectivityResult) {
        case ConnectivityResult.wifi:
          _isWifi = true;
          break;
        case ConnectivityResult.mobile:
          _isMobile = true;
          break;
        default:
          _isWifi = false;
          _isMobile = false;
      }
      _sendUiUpdates();
    // } else if (event.runtimeType == BatteryState) {
    //   // log("BATT " + (event as BatteryState).toString());
    //   _updateBatteryStatus(event);
    } else if (event.runtimeType == String) {
      var result = BeaconResult.fromJson(jsonDecode(event));
      beacons[result.name] = BluetoothBeacon(
          macAddress: result.macAddress,
          beaconMajor: result.major,
          beaconMinor: result.minor,
          hasTeslaService: false,
          isConnectable: false,
          lastSeen: DateTime.now(),
          deviceName: result.name,
          rssi: result.rssi,
          txPower: result.txPower);

      if (!_bleConnected) {}
      _updateBeaconStatus(result);
      // Message Parsing starts here
    } else if (event.runtimeType == CharacteristicValue) {
      List<int> bytes = [];
      try {
        bytes = (event as CharacteristicValue).result.dematerialize();
      } catch (e) {
        log(e.toString(), time: DateTime.now(), level: 0, name: 'Service');
      }

      if (true) {
        //  (isFullMessage(bytes)) {
        FromVCSECMessage? fromVCSEC = null;
        if (isFullMessage(bytes)) {
          log("FULL MESSAGE!");
        }

        // is there a partial message from this device?

        if (bytes.length > 2) {
          try {
            fromVCSEC = FromVCSECMessage.fromBuffer(bytes.sublist(2));
          } on Exception catch (e) {}
        }
        if ((event as CharacteristicValue)
                .characteristic
                .deviceId
                .compareTo(_newVehicleId) ==
            0) {
          if (fromVCSEC != null) {
            log("MESSAGE: " + fromVCSEC.toString(),
                time: DateTime.now(), level: 0);
            _advanceNewVehicleProcess(fromVCSEC);
          } else {
            _advanceNewVehicleProcess();
          }
        } else if (event.characteristic.deviceId.compareTo(_newVehicleId) ==
            0) {
          // _onboardVehicleId
          if (fromVCSEC != null) {
            log("MESSAGE: " + fromVCSEC.toString(),
                time: DateTime.now(), level: 0);
          } else {}
          List<int> keyId = base64Decode(_obVehicle.crKeyId);
          List<int> sharedKey = base64Decode(_obVehicle.crShared);
          //
          // if (!hasTest) {
          //   _sendToVehicle(_newVehicleId, await requestVehicleVin( // _onboardVehicleId
          //       keyId, 7, sharedKey)); // _obVehicle.crCounter got manually replaced by value
          //   hasTest=true;
          // }
        }

        /* ##############################################################
           ##          Message-Parser
           ############################################################## */

        VehicleState? vehicleState =
            _managedVehicles[event.characteristic.deviceId];
        bool isNotify = false;
        bool isState = false;
        bool isVehicle = false;
        Vehicle? vehicle =
            _getEnrolledVehicleByAddress(event.characteristic.deviceId);
        // Nachricht an connected Device
        if ((fromVCSEC != null) && (vehicle != null)) {
          if (fromVCSEC.hasAuthenticationRequest()) {
            //if (_managedVehicles.containsKey(event.characteristic.deviceId)) {
            if (fromVCSEC.authenticationRequest.hasSessionInfo()) {
              // TODO: Check if passive entry parameters match
              _sendToVehicle(
                  vehicle.btAddress,
                  await answerAuthorizationRequestToken(
                      base64Decode(vehicle.crKeyId),
                      vehicle.getCounter(),
                      base64Decode(vehicle.crShared),
                      fromVCSEC.authenticationRequest.sessionInfo.token,
                      fromVCSEC.authenticationRequest.requestedLevel,
                      1));
            } else {
              _sendToVehicle(
                  vehicle.btAddress,
                  await answerAuthorizationRequest(
                      base64Decode(vehicle.crKeyId),
                      vehicle.getCounter(),
                      base64Decode(vehicle.crShared),
                      fromVCSEC.authenticationRequest.requestedLevel));
            }
            //}
          } else if (fromVCSEC.hasCommandStatus()) {
            if (fromVCSEC.commandStatus.hasSignedMessageStatus()) {
              if ((fromVCSEC.commandStatus.signedMessageStatus.hasCounter()) &&
                  !(fromVCSEC.commandStatus.hasOperationStatus())) {
                TeslaKeeDatabase.instance.updateVehicleCounter(vehicle.id ?? 0,
                    fromVCSEC.commandStatus.signedMessageStatus.counter);
              } else {
                log("XXX " + fromVCSEC.toString());
              }
            } else if (fromVCSEC.commandStatus.hasOperationStatus()) {
              if ((fromVCSEC.commandStatus.operationStatus ==
                      OperationStatus_E.OPERATIONSTATUS_ERROR) &&
                  (fromVCSEC.commandStatus.hasSignedMessageStatus())) {
                switch (fromVCSEC.commandStatus.signedMessageStatus
                    .signedMessageInformation) {
                  case SignedMessage_information_E
                      .SIGNEDMESSAGE_INFORMATION_FAULT_NOT_ON_WHITELIST:
                    // TODO: Trouble
                    break;
                  case SignedMessage_information_E
                      .SIGNEDMESSAGE_INFORMATION_FAULT_IV_SMALLER_THAN_EXPECTED:
                    // TODO: request Session Info
                    break;
                  case SignedMessage_information_E
                      .SIGNEDMESSAGE_INFORMATION_FAULT_TOKEN_AND_COUNTER_INVALID:
                    // TODO: request Session Info
                    break;
                  case SignedMessage_information_E
                      .SIGNEDMESSAGE_INFORMATION_FAULT_INVALID_TOKEN:
                    // TODO: request Session Info
                    break;
                }
              }
            } else if (fromVCSEC.hasVehicleStatus()) {
              if ((fromVCSEC.vehicleStatus.hasVehicleLockState()) &&
                  (fromVCSEC.vehicleStatus.vehicleLockState ==
                      VehicleLockState_E.VEHICLELOCKSTATE_LOCKED)) {
                unlockedVehicles.remove(vehicle.vin);
              } else if (fromVCSEC.commandStatus.hasOperationStatus()) {
                unlockedVehicles.remove(vehicle.vin);
              }
            } else {
              unlockedVehicles.add(vehicle.vin);
            }
          }

          //
          // if (fromVCSEC.hasPersonalizationInformation()) {
          //   if (fromVCSEC.personalizationInformation.hasVIN()) {
          //     List<int> vIN = fromVCSEC.personalizationInformation.vIN;
          //     print("VIN: " + vIN.toString());
          //   }
          // }

          if (fromVCSEC.hasVehicleStatus() && (vehicle != null)) {
            if (fromVCSEC.vehicleStatus.hasVehicleLockState()) {
              fromVCSEC.vehicleStatus.vehicleLockState;
              // TODO: do something with it
            }
            if (fromVCSEC.vehicleStatus.hasClosureStatuses()) {
              log(fromVCSEC.vehicleStatus.closureStatuses.toString());
            }
            // if (fromVCSEC.vehicleStatus.hasClosureStatuses()) {
            //   ClosureStatuses cStates = fromVCSEC.vehicleStatus
            //       .closureStatuses;
            //   if (cStates.hasChargePort())
            //     vehicleState.closureChargePort =
            //         cStates.chargePort.value;
            //   if (cStates.hasFrontDriverDoor())
            //     vehicleState.closureFrontDriver =
            //         cStates.frontDriverDoor.value;
            //   if (cStates.hasFrontPassengerDoor())
            //     vehicleState.closureFrontPassenger =
            //         cStates.frontPassengerDoor.value;
            //   if (cStates.hasRearDriverDoor())
            //     vehicleState.closureRearDriver =
            //         cStates.rearDriverDoor.value;
            //   if (cStates.hasRearPassengerDoor())
            //     vehicleState.closureRearPassenger =
            //         cStates.rearPassengerDoor.value;
            //   if (cStates.hasFrontTrunk())
            //     vehicleState.closureFrunk =
            //         cStates.frontTrunk.value;
            //   if (cStates.hasRearTrunk())
            //     vehicleState.closureTrunk =
            //         cStates.rearTrunk.value;
            // }
          }

          if (fromVCSEC.hasVehicleInfo()) {
            if (fromVCSEC.vehicleInfo.hasVIN()) {
              print("VIN " + fromVCSEC.vehicleInfo.vIN);
            }
          }

          if (fromVCSEC.hasKeyStatusInfo()) {
            if (fromVCSEC.keyStatusInfo == KeyStatusInfo) {}
          }

          if (fromVCSEC.hasSessionInfo()) {}

          if (fromVCSEC.hasUnknownKeyInfo()) {}

          if (fromVCSEC.hasUnsecureNotification()) {
            if (fromVCSEC.unsecureNotification.hasNotifyUser()) isNotify = true;
          }

          if (fromVCSEC.hasUnsecureNotification()) {}

          Uint8List message = Uint8List.fromList(bytes);
          if ((message.lengthInBytes >= 4) &&
              !(_toHexString(message, 2).contains('1a00'))) {
            log("VCSEC " + fromVCSEC.toString());
          }
        }
      } else {}
    } else if (event.runtimeType == Position) {
      // log("LOCA " + (event as Position).toString());
      _updateLocationStatus(event);
    } else if (event.runtimeType == ConnectionStateUpdate) {
      // BLE connection
      if (((event).deviceId.compareTo(_newVehicleId) == 0) &&
          ((event).connectionState == DeviceConnectionState.connected)) {
        _subscribeCharacteristic(_newVehicleId);
        _newVehicleTickleTimer = Timer(
            Duration(seconds: 3),
            () => _sendToVehicle(
                _newVehicleId, requestStatus(_newVehiclePhoneKeyId)));
      } else if (((event).deviceId.compareTo(_newVehicleId) == 0) &&
          ((event).connectionState == DeviceConnectionState.connected)) {
        _subscribeCharacteristic(_newVehicleId); // _onboardVehicleId
        _newVehicleTickleTimer = Timer(
            Duration(microseconds: 500),
            () => _sendToVehicle(
                _newVehicleId,
                requestStatus(
                    base64Decode(_obVehicle.crKeyId)))); // _onboardVehicleId
      } else if (((event).deviceId.compareTo(_newVehicleId) == 0) &&
          (!_bleConnected)) {
        // check against enrolled vehicles
        // _subscribeCharacteristic((event as ConnectionStateUpdate).deviceId);
        //print ("BCON:"+(event as ConnectionStateUpdate).deviceId);
      } else if (((event).connectionState == DeviceConnectionState.connected)) {
        //_bleConnected = false;
        //_sendUiUpdates();
        _subscribeCharacteristic(event.deviceId);
      } else if (((event).connectionState ==
          DeviceConnectionState.disconnected)) {
        connectedVehicles.remove((event as ConnectionStateUpdate).deviceId);
        _bleConnected = false;
        _sendUiUpdates();
        // log("BCON " +
        //     (event).deviceId +
        //     " - " +
        //     (event).connectionState.toString());
      }

      _updateConnectionStatus(event);
    } else if (event.runtimeType
        .toString()
        .contains("_InternalLinkedHashMap")) {
      if (event["action"] == "requestUpdate") {
        //print("requestUpdate called");
        _sendUiUpdates();
      }

      // if ((event["setEnrolledVehicles"]!=null)&&(event["setEnrolledVehicles"].toString().length>0)) {
      //   _setEnrolledVehicles(event["setEnrolledVehicles"]);
      // }

      if ((event["addVehicle"] != null) &&
          (event["addVehicle"].toString().length > 0)) {
        log("ADDVEHICLE " + event.toString());
        _addNewVehicle(event["addVehicle"]);
      }

      // if ((event["onboardVehicle"]!=null)&&(event["onboardVehicle"].toString().length>0)) {
      //   _onboardVehicle(event["onboardVehicle"]);
      // }

      if (event["action"] == "startBeacon") {
        //_startBeacon();
      }

      if (event["activeUiVehicle"] != null) {
        _currentUiVehicle = event["activeUiVehicle"];
      }

      if (event["buttonUnlockCar"] != null) {
        String vehicleId = event["buttonUnlockCar"];
        _getWhitelistInfo(vehicleId);
      }

      if (event["buttonOpenFrunk"] != null) {
        String vehicleId = event["buttonOpenFrunk"];
        _getVehicleInfo(vehicleId);
      }

      if (event["buttonOpenTrunk"] != null) {
        String vehicleId = event["buttonOpenTrunk"];
        _getStatus(vehicleId);
      }

      if (event["buttonOpenButthole"] != null) {
        String vehicleId = event["buttonOpenButthole"];
        _openChargePort(vehicleId);
      }

      if (event["buttonLockSafe"] != null) {
        String vehicleId = event["buttonLockSafe"];
        _getEphemeralPublicKey(vehicleId);
      }
    } else {
      log(
        "EVNT " + event.toString() + " " + event.runtimeType.toString(),
        time: DateTime.now(),
      );
      log(".", time: DateTime.now(), level: 0);
    }
  }

  Vehicle? _getEnrolledVehicleByAddress(String id) {
    Vehicle? retVal = null;
    enrolledVehicles.forEach((key, value) {
      if (value.btAddress.compareTo(id) == 0) {
        retVal = value;
      }
    });
    return retVal;
  }

  Vehicle? _getEnrolledVehicleByVin(String vin) {
    Vehicle? retVal = null;
    enrolledVehicles.forEach((key, value) {
      if (value.vin.compareTo(vin) == 0) {
        retVal = value;
      }
    });
    return retVal;
  }
}
