#!/usr/bin/env python3
"""
E-Bike Bluetooth Low Energy (BLE) Host Daemon for Raspberry Pi 4B
-----------------------------------------------------------------
Features:
- BlueZ D-Bus GATT Server advertising custom E-Bike Service
- Telemetry Characteristic (Read / Notify) for live sensor data
- Control Characteristic (Write) for mobile commands (mode, lock, lights)
- LE Advertisement as 'Volt-EBike-RPI4'
- BlueZ Pairing Agent ('NoInputNoOutput') for zero-hassle mobile pairing
- Bidirectional WebSocket bridge with Flutter display app (ws://127.0.0.1:5001/ws)
"""

import sys
import json
import time
import asyncio
import threading
import urllib.request
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

try:
    import websockets
except ImportError:
    websockets = None

# -------------------------------------------------------------
# UUIDs (128-bit Custom Volt E-Bike Service & Characteristics)
# -------------------------------------------------------------
EBIKE_SERVICE_UUID = "19b10000-e8f2-537e-4f6c-d104768a1214"
TELEMETRY_CHAR_UUID = "19b10001-e8f2-537e-4f6c-d104768a1214"
CONTROL_CHAR_UUID   = "19b10002-e8f2-537e-4f6c-d104768a1214"

BLUEZ_SERVICE_NAME = "org.bluez"
GATT_MANAGER_IFACE = "org.bluez.GattManager1"
DBUS_OM_IFACE = "org.freedesktop.DBus.ObjectManager"
DBUS_PROP_IFACE = "org.freedesktop.DBus.Properties"
LE_ADVERTISING_MANAGER_IFACE = "org.bluez.LEAdvertisingManager1"
LE_ADVERTISEMENT_IFACE = "org.bluez.LEAdvertisement1"
AGENT_MANAGER_IFACE = "org.bluez.AgentManager1"
AGENT_IFACE = "org.bluez.Agent1"

# Shared in-memory state
bike_state = {
    "speed": 0.0,
    "mode": "SPORT",
    "mode_id": 3,
    "battery": 84,
    "range": 68,
    "locked": False,
    "lights": "low_beam",
    "indicator": "none",
    "reverse": False,
    "temp": 37.0,
    "smoke": 0,
    "connected_phone": None
}

# Pre-read hardware temperature on launch if available
try:
    with open("/sys/class/thermal/thermal_zone0/temp", "r") as _tf:
        bike_state["temp"] = round(float(_tf.read().strip()) / 1000.0, 1)
except Exception:
    pass

ws_outgoing_queue = []
active_telemetry_char = None


def forward_command_to_display(cmd):
    """Forwards a command from phone to Flutter display via WebSocket and HTTP fallback."""
    msg = json.dumps({
        "source": "mobile_bluetooth",
        "command": cmd
    })
    ws_outgoing_queue.append(msg)

    def _http_post():
        try:
            req = urllib.request.Request(
                "http://127.0.0.1:5000/command",
                data=msg.encode("utf-8"),
                headers={"Content-Type": "application/json"}
            )
            urllib.request.urlopen(req, timeout=1.5)
        except Exception:
            pass

    threading.Thread(target=_http_post, daemon=True).start()


def notify_bluetooth_status(status, device_name):
    """Notifies Flutter display of phone connection state via WebSocket and HTTP fallback."""
    msg = json.dumps({
        "type": "bluetooth_status",
        "status": status,
        "device_name": device_name
    })
    ws_outgoing_queue.append(msg)

    def _http_post():
        try:
            req = urllib.request.Request(
                "http://127.0.0.1:5000/command",
                data=msg.encode("utf-8"),
                headers={"Content-Type": "application/json"}
            )
            urllib.request.urlopen(req, timeout=1.5)
        except Exception:
            pass

    threading.Thread(target=_http_post, daemon=True).start()


# =============================================================
# BlueZ GATT Service & Characteristic Implementations
# =============================================================

class Application(dbus.service.Object):
    def __init__(self, bus):
        self.path = "/"
        self.services = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_service(self, service):
        self.services.append(service)

    @dbus.service.method(DBUS_OM_IFACE, out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        response = {}
        for service in self.services:
            response[service.get_path()] = service.get_properties()
            chrcs = service.get_characteristics()
            for chrc in chrcs:
                response[chrc.get_path()] = chrc.get_properties()
                descs = chrc.get_descriptors()
                for desc in descs:
                    response[desc.get_path()] = desc.get_properties()
        return response


class Service(dbus.service.Object):
    PATH_BASE = "/org/bluez/example/service"

    def __init__(self, bus, index, uuid, primary):
        self.path = self.PATH_BASE + str(index)
        self.bus = bus
        self.uuid = uuid
        self.primary = primary
        self.characteristics = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self):
        return {
            "org.bluez.GattService1": {
                "UUID": self.uuid,
                "Primary": self.primary,
                "Characteristics": dbus.Array(
                    [c.get_path() for c in self.characteristics],
                    signature="o"
                )
            }
        }

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_characteristic(self, characteristic):
        self.characteristics.append(characteristic)

    def get_characteristics(self):
        return self.characteristics


class Characteristic(dbus.service.Object):
    def __init__(self, bus, index, uuid, flags, service):
        self.path = service.path + "/char" + str(index)
        self.bus = bus
        self.uuid = uuid
        self.service = service
        self.flags = flags
        self.descriptors = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self):
        return {
            "org.bluez.GattCharacteristic1": {
                "Service": self.service.get_path(),
                "UUID": self.uuid,
                "Flags": self.flags,
                "Descriptors": dbus.Array(
                    [d.get_path() for d in self.descriptors],
                    signature="o"
                )
            }
        }

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_descriptor(self, descriptor):
        self.descriptors.append(descriptor)

    def get_descriptors(self):
        return self.descriptors

    @dbus.service.method(DBUS_PROP_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != "org.bluez.GattCharacteristic1":
            raise dbus.exceptions.DBusException(
                "org.freedesktop.DBus.Error.InvalidArgs",
                "Interface is invalid"
            )
        return self.get_properties()["org.bluez.GattCharacteristic1"]


class TelemetryCharacteristic(Characteristic):
    """Provides real-time e-bike metrics (speed, battery, mode, indicators)."""

    def __init__(self, bus, index, service):
        Characteristic.__init__(
            self, bus, index,
            TELEMETRY_CHAR_UUID,
            ["read", "notify"],
            service
        )
        self.notifying = False
        global active_telemetry_char
        active_telemetry_char = self

    def notify_telemetry(self):
        if not self.notifying:
            return

        # Dynamically read thermal sensor from Raspberry Pi
        try:
            with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
                cputemp = float(f.read().strip()) / 1000.0
                bike_state["temp"] = round(cputemp, 1)
        except Exception:
            pass

        payload = json.dumps(bike_state).encode("utf-8")
        value = [dbus.Byte(b) for b in payload]
        self.PropertiesChanged(
            "org.bluez.GattCharacteristic1",
            {"Value": value},
            []
        )

    @dbus.service.method("org.bluez.GattCharacteristic1", in_signature="a{sv}", out_signature="ay")
    def ReadValue(self, options):
        payload = json.dumps(bike_state).encode("utf-8")
        return [dbus.Byte(b) for b in payload]

    @dbus.service.method("org.bluez.GattCharacteristic1")
    def StartNotify(self):
        if self.notifying:
            return
        print("[BLE Host] Telemetry notifications started")
        self.notifying = True
        self.notify_telemetry()
        # Notify display that phone is connected
        notify_bluetooth_status("connected", bike_state.get("connected_phone") or "Phone")

    @dbus.service.method("org.bluez.GattCharacteristic1")
    def StopNotify(self):
        if not self.notifying:
            return
        print("[BLE Host] Telemetry notifications stopped")
        self.notifying = False
        # Notify display that phone disconnected
        notify_bluetooth_status("advertising", None)

    @dbus.service.signal(DBUS_PROP_IFACE, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass


class ControlCharacteristic(Characteristic):
    """Receives remote commands from the mobile app (lock, mode, lights, navigation)."""

    def __init__(self, bus, index, service):
        Characteristic.__init__(
            self, bus, index,
            CONTROL_CHAR_UUID,
            ["write", "write-without-response"],
            service
        )
        self._write_buffer = bytearray()
        self._last_write_time = 0.0

    @dbus.service.method("org.bluez.GattCharacteristic1", in_signature="aya{sv}")
    def WriteValue(self, value, options):
        raw_bytes = bytes(value)
        now = time.time()

        # If last write was more than 2.5 seconds ago, reset stale buffer
        if now - self._last_write_time > 2.5:
            self._write_buffer = bytearray()
        self._last_write_time = now

        # If a fresh JSON message start ('{') arrives and the previous buffer was already parsed or invalid
        if raw_bytes.startswith(b'{') and len(self._write_buffer) > 0:
            try:
                # Check if buffer in progress is already valid JSON
                json.loads(self._write_buffer.decode("utf-8"))
                self._write_buffer = bytearray()
            except Exception:
                # Buffer has invalid/stale partial data, reset for new message
                self._write_buffer = bytearray()

        self._write_buffer.extend(raw_bytes)

        try:
            cmd_text = self._write_buffer.decode("utf-8").strip()
            cmd = json.loads(cmd_text)
            # Successfully parsed full JSON payload - reset buffer for next command
            self._write_buffer = bytearray()
            print(f"[BLE Host] Received command from mobile: {cmd}")

            action = cmd.get("action") or cmd.get("cmd")
            val = cmd.get("val") if "val" in cmd else cmd.get("value")

            # Always mark phone as connected on receiving any command
            if action == "phone_connected":
                phone_name = val.get("device_name", "Phone") if isinstance(val, dict) else str(val or "Phone")
                bike_state["connected_phone"] = phone_name
                notify_bluetooth_status("connected", phone_name)
            else:
                notify_bluetooth_status("connected", bike_state.get("connected_phone") or "Phone")

            if action == "set_mode":
                bike_state["mode"] = str(val).upper()
            elif action == "set_lock":
                bike_state["locked"] = bool(val)
            elif action == "set_lights":
                bike_state["lights"] = str(val)

            # Forward message to Flutter display over WebSocket & HTTP fallback
            forward_command_to_display(cmd)

            # Trigger immediate telemetry notify so mobile UI confirms update
            if active_telemetry_char:
                active_telemetry_char.notify_telemetry()

        except (json.JSONDecodeError, UnicodeDecodeError):
            # Partial chunk of multi-packet payload - hold in buffer and wait for subsequent chunks
            pass
        except Exception as e:
            print(f"[BLE Host] Error handling command: {e}")
            self._write_buffer = bytearray()


class EbikeGattService(Service):
    def __init__(self, bus, index):
        Service.__init__(self, bus, index, EBIKE_SERVICE_UUID, True)
        self.add_characteristic(TelemetryCharacteristic(bus, 0, self))
        self.add_characteristic(ControlCharacteristic(bus, 1, self))


# =============================================================
# BlueZ LE Advertisement
# =============================================================

class Advertisement(dbus.service.Object):
    PATH_BASE = "/org/bluez/example/advertisement"

    def __init__(self, bus, index, advertising_type):
        self.path = self.PATH_BASE + str(index)
        self.bus = bus
        self.ad_type = advertising_type
        self.service_uuids = [EBIKE_SERVICE_UUID]
        self.local_name = "Volt-EBike-RPI4"
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self):
        properties = {
            "Type": self.ad_type,
            "ServiceUUIDs": dbus.Array(self.service_uuids, signature="s"),
            "LocalName": dbus.String(self.local_name),
        }
        return {"org.bluez.LEAdvertisement1": properties}

    def get_path(self):
        return dbus.ObjectPath(self.path)

    @dbus.service.method(DBUS_PROP_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != LE_ADVERTISEMENT_IFACE:
            raise dbus.exceptions.DBusException(
                "org.freedesktop.DBus.Error.InvalidArgs",
                "Interface is invalid"
            )
        return self.get_properties()["org.bluez.LEAdvertisement1"]

    @dbus.service.method(LE_ADVERTISEMENT_IFACE, in_signature="", out_signature="")
    def Release(self):
        print(f"[BLE Host] Advertisement {self.path} released")


# =============================================================
# BlueZ Auto-Pairing Agent (NoInputNoOutput)
# =============================================================

class AutoPairingAgent(dbus.service.Object):
    AGENT_PATH = "/org/bluez/agent/ebike"

    def __init__(self, bus):
        self.bus = bus
        dbus.service.Object.__init__(self, bus, self.AGENT_PATH)

    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Release(self):
        print("[BLE Host] Pairing Agent released")

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        print(f"[BLE Host] Auto-accepting PIN for device {device}: '0000'")
        return "0000"

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        print(f"[BLE Host] RequestPasskey for {device}: auto 0")
        return dbus.UInt32(0)

    @dbus.service.method(AGENT_IFACE, in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        print(f"[BLE Host] Auto-confirming passkey {passkey} for {device}")
        return

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        print(f"[BLE Host] Auto-authorizing service {uuid} for {device}")
        return

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        print(f"[BLE Host] Auto-authorizing connection for {device}")
        return

    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Cancel(self):
        print("[BLE Host] Pairing request canceled by remote")


# =============================================================
# WebSocket Client: Synchronizes with Flutter Display App
# =============================================================

async def flutter_display_sync_loop():
    """Connects to the Flutter display's local WebSocket server (port 5001)."""
    uri = "ws://127.0.0.1:5001/ws"
    while True:
        try:
            if not websockets:
                # If websockets library is not installed, fallback gracefully
                await asyncio.sleep(2)
                continue

            async with websockets.connect(uri) as ws:
                print(f"[BLE Host] Connected to Flutter Display WS at {uri}")

                # Notify display that Bluetooth host is active
                await ws.send(json.dumps({
                    "type": "bluetooth_status",
                    "status": "advertising",
                    "device_name": "Volt-EBike-RPI4"
                }))

                async def receiver():
                    async for message in ws:
                        try:
                            data = json.loads(message)
                            # Update local state if display sent sensor metrics
                            if isinstance(data, dict):
                                for k in ["speed", "mode", "mode_id", "battery", "range",
                                          "locked", "lights", "indicator", "reverse", "temp", "smoke"]:
                                    if k in data:
                                        bike_state[k] = data[k]

                                if active_telemetry_char:
                                    active_telemetry_char.notify_telemetry()
                        except Exception:
                            pass

                async def sender():
                    while True:
                        if ws_outgoing_queue:
                            msg = ws_outgoing_queue.pop(0)
                            await ws.send(msg)
                        await asyncio.sleep(0.05)

                await asyncio.gather(receiver(), sender())

        except Exception as e:
            # Reconnect after 3 seconds if Flutter display is restarting
            await asyncio.sleep(3)


def start_asyncio_thread():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    loop.run_until_complete(flutter_display_sync_loop())


# =============================================================
# Main Entry Point
# =============================================================

def find_adapter(bus, retries=15, delay=1.0):
    for i in range(retries):
        try:
            remote_om = dbus.Interface(bus.get_object(BLUEZ_SERVICE_NAME, "/"), DBUS_OM_IFACE)
            objects = remote_om.GetManagedObjects()
            for o, props in objects.items():
                if GATT_MANAGER_IFACE in props.keys():
                    return o
        except Exception:
            pass
        if i < retries - 1:
            time.sleep(delay)
    return None


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()

    adapter_path = find_adapter(bus)
    if not adapter_path:
        print("[BLE Host] Error: BlueZ GattManager1 interface not found. Is bluetooth running?")
        sys.exit(1)

    print(f"[BLE Host] Using Bluetooth adapter: {adapter_path}")

    # Power on adapter & set discoverable
    adapter_props = dbus.Interface(
        bus.get_object(BLUEZ_SERVICE_NAME, adapter_path),
        DBUS_PROP_IFACE
    )
    adapter_props.Set("org.bluez.Adapter1", "Powered", dbus.Boolean(True))
    adapter_props.Set("org.bluez.Adapter1", "Discoverable", dbus.Boolean(True))
    adapter_props.Set("org.bluez.Adapter1", "Pairable", dbus.Boolean(True))

    # Register Pairing Agent
    agent = AutoPairingAgent(bus)
    agent_manager = dbus.Interface(
        bus.get_object(BLUEZ_SERVICE_NAME, "/org/bluez"),
        AGENT_MANAGER_IFACE
    )
    try:
        agent_manager.UnregisterAgent(agent.AGENT_PATH)
    except Exception:
        pass
    try:
        agent_manager.RegisterAgent(agent.AGENT_PATH, "NoInputNoOutput")
        agent_manager.RequestDefaultAgent(agent.AGENT_PATH)
        print("[BLE Host] Auto-pairing agent registered ('NoInputNoOutput')")
    except Exception as e:
        print(f"[BLE Host] Pairing agent note: {e}")

    # Register GATT Application
    service_manager = dbus.Interface(
        bus.get_object(BLUEZ_SERVICE_NAME, adapter_path),
        GATT_MANAGER_IFACE
    )
    app = Application(bus)
    app.add_service(EbikeGattService(bus, 0))

    # Register LE Advertisement
    ad_manager = dbus.Interface(
        bus.get_object(BLUEZ_SERVICE_NAME, adapter_path),
        LE_ADVERTISING_MANAGER_IFACE
    )
    advertisement = Advertisement(bus, 0, "peripheral")

    mainloop = GLib.MainLoop()

    def register_app_cb():
        print("[BLE Host] GATT application registered successfully!")

    def register_app_error_cb(error):
        print(f"[BLE Host] Failed to register GATT app: {error}")
        mainloop.quit()

    def register_ad_cb():
        print(f"[BLE Host] LE Advertisement active as '{advertisement.local_name}' (Ready for phone to pair)")

    def register_ad_error_cb(error):
        print(f"[BLE Host] Advertisement note: {error} (Adapter remains discoverable via system bluetoothctl)")

    service_manager.RegisterApplication(
        app.get_path(), {},
        reply_handler=register_app_cb,
        error_handler=register_app_error_cb
    )

    ad_manager.RegisterAdvertisement(
        advertisement.get_path(), {},
        reply_handler=register_ad_cb,
        error_handler=register_ad_error_cb
    )

    # Listen for any device connecting/disconnecting at the BlueZ radio layer
    def on_device_properties_changed(interface, changed_properties, invalidated_properties, path):
        if interface == "org.bluez.Device1":
            if "Connected" in changed_properties:
                is_conn = bool(changed_properties["Connected"])
                if is_conn:
                    try:
                        dev_obj = bus.get_object(BLUEZ_SERVICE_NAME, path)
                        dev_props = dbus.Interface(dev_obj, DBUS_PROP_IFACE)
                        name = str(dev_props.Get("org.bluez.Device1", "Alias"))
                    except Exception:
                        name = "Phone"
                    print(f"[BLE Host] Device connected: {name} ({path})")
                    bike_state["connected_phone"] = name
                    notify_bluetooth_status("connected", name)
                else:
                    print(f"[BLE Host] Device disconnected: {path}")
                    bike_state["connected_phone"] = None
                    notify_bluetooth_status("advertising", "Volt-EBike-RPI4")

    bus.add_signal_receiver(
        on_device_properties_changed,
        dbus_interface="org.freedesktop.DBus.Properties",
        signal_name="PropertiesChanged",
        arg0="org.bluez.Device1",
        path_keyword="path"
    )

    # Start the background WebSocket synchronization client thread with Flutter display
    ws_thread = threading.Thread(target=start_asyncio_thread, daemon=True)
    ws_thread.start()
    print("[BLE Host] Background display sync thread started")

    # Periodic background telemetry broadcast loop (every 1.0 second over BLE to connected phone)
    def periodic_telemetry_tick():
        if active_telemetry_char and active_telemetry_char.notifying:
            try:
                active_telemetry_char.notify_telemetry()
            except Exception:
                pass
        return True

    GLib.timeout_add_seconds(1, periodic_telemetry_tick)
    print("[BLE Host] 1 Hz real-time telemetry streaming timer registered")

    print("[BLE Host] Daemon started. Press Ctrl+C to terminate.")
    try:
        mainloop.run()
    except KeyboardInterrupt:
        print("\n[BLE Host] Terminating...")
    finally:
        try:
            ad_manager.UnregisterAdvertisement(advertisement.get_path())
        except Exception:
            pass


if __name__ == "__main__":
    main()
