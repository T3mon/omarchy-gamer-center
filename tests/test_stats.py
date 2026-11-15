import importlib.machinery
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


stats = load("gamercenter_stats", os.path.join(HERE, "..", "bin", "gamercenter-stats"))


class Tree:
    """A throwaway /proc + /sys tree."""

    def __init__(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = self._tmp.name
        self.fs = stats.Fs(self.root)

    def close(self):
        self._tmp.cleanup()

    def write(self, path, text):
        full = self.root + path
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(text)

    def link(self, path, target):
        full = self.root + path
        os.makedirs(os.path.dirname(full), exist_ok=True)
        os.symlink(target, full)

    def fdinfo(self, pid, fd, client, render_ns, pdev="0000:00:02.0", driver="i915", extra=""):
        self.write("/proc/%d/fdinfo/%d" % (pid, fd),
                   "pos:\t0\ndrm-driver:\t%s\ndrm-client-id:\t%s\ndrm-pdev:\t%s\n"
                   "drm-total-system0:\t1024 KiB\ndrm-engine-render:\t%d ns\n"
                   "drm-engine-video:\t0 ns\ndrm-engine-capacity-video:\t2\n%s"
                   % (driver, client, pdev, render_ns, extra))

    def gpu(self, card, slot, vendor, driver):
        dev = "/sys/devices/pci0000:00/%s" % slot
        self.write(dev + "/vendor", vendor + "\n")
        self.write(dev + "/power/runtime_status", "active\n")
        self.write(dev + "/power/control", "auto\n")
        os.makedirs(self.root + "/sys/bus/pci/drivers/" + driver, exist_ok=True)
        self.link(dev + "/driver", self.root + "/sys/bus/pci/drivers/" + driver)
        self.link("/sys/class/drm/%s/device" % card, self.root + dev)
        return dev


class CpuAndMemory(unittest.TestCase):
    def test_load_from_two_samples(self):
        a = stats.parse_proc_stat("cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 2 3 4\n")
        b = stats.parse_proc_stat("cpu  200 0 200 1300 100 0 0 0 0 0\n")
        # 200 busy jiffies out of 800 elapsed.
        self.assertEqual(stats.cpu_load(a, b), 25.0)
        self.assertIsNone(stats.cpu_load(None, b))
        self.assertIsNone(stats.cpu_load(b, b))

    def test_memory_in_mib(self):
        t = Tree()
        self.addCleanup(t.close)
        t.write("/proc/meminfo", "MemTotal:       16384000 kB\nMemFree: 1 kB\nMemAvailable:    8192000 kB\n")
        self.assertEqual(stats.memory(t.fs), {"used": 8000, "total": 16000})

    def test_package_sensor_beats_core_and_acpi(self):
        t = Tree()
        self.addCleanup(t.close)
        t.write("/sys/class/hwmon/hwmon0/name", "acpitz\n")
        t.write("/sys/class/hwmon/hwmon0/temp1_input", "40000\n")
        t.write("/sys/class/hwmon/hwmon1/name", "coretemp\n")
        t.write("/sys/class/hwmon/hwmon1/temp2_label", "Core 0\n")
        t.write("/sys/class/hwmon/hwmon1/temp2_input", "61000\n")
        t.write("/sys/class/hwmon/hwmon1/temp1_label", "Package id 0\n")
        t.write("/sys/class/hwmon/hwmon1/temp1_input", "63000\n")
        self.assertEqual(stats.find_cpu_temp(t.fs), "/sys/class/hwmon/hwmon1/temp1_input")

    def test_amd_die_sensor_beats_control(self):
        t = Tree()
        self.addCleanup(t.close)
        t.write("/sys/class/hwmon/hwmon3/name", "k10temp\n")
        t.write("/sys/class/hwmon/hwmon3/temp1_label", "Tctl\n")
        t.write("/sys/class/hwmon/hwmon3/temp1_input", "70000\n")
        t.write("/sys/class/hwmon/hwmon3/temp2_label", "Tdie\n")
        t.write("/sys/class/hwmon/hwmon3/temp2_input", "60000\n")
        self.assertEqual(stats.find_cpu_temp(t.fs), "/sys/class/hwmon/hwmon3/temp2_input")

    def test_fastest_core_wins(self):
        t = Tree()
        self.addCleanup(t.close)
        t.write("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "1200000\n")
        t.write("/sys/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq", "3850000\n")
        t.write("/sys/devices/system/cpu/cpufreq/boost", "1\n")
        self.assertEqual(stats.cpu_mhz(t.fs, stats.cpu_freq_paths(t.fs)), 3850)


class Battery(unittest.TestCase):
    def test_current_times_voltage_and_peripherals_ignored(self):
        t = Tree()
        self.addCleanup(t.close)
        t.write("/sys/class/power_supply/BAT1/type", "Battery\n")
        t.write("/sys/class/power_supply/BAT1/status", "Discharging\n")
        t.write("/sys/class/power_supply/BAT1/current_now", "1500000\n")
        t.write("/sys/class/power_supply/BAT1/voltage_now", "11400000\n")
        t.write("/sys/class/power_supply/hidpp_battery_0/type", "Battery\n")
        t.write("/sys/class/power_supply/hidpp_battery_0/scope", "Device\n")
        t.write("/sys/class/power_supply/hidpp_battery_0/status", "Discharging\n")
        t.write("/sys/class/power_supply/hidpp_battery_0/power_now", "9000000\n")
        t.write("/sys/class/power_supply/ACAD/type", "Mains\n")
        self.assertEqual(stats.battery(t.fs), {"watts": 17.1, "state": "discharging"})

    def test_on_ac(self):
        t = Tree()
        self.addCleanup(t.close)
        t.write("/sys/class/power_supply/BAT0/type", "Battery\n")
        t.write("/sys/class/power_supply/BAT0/status", "Not charging\n")
        t.write("/sys/class/power_supply/BAT0/power_now", "0\n")
        self.assertEqual(stats.battery(t.fs), {"watts": 0.0, "state": "ac"})

    def test_no_battery(self):
        t = Tree()
        self.addCleanup(t.close)
        self.assertIsNone(stats.battery(t.fs))


class IntelUsage(unittest.TestCase):
    def setUp(self):
        self.t = Tree()
        self.addCleanup(self.t.close)

    def test_engine_time_over_wall_time(self):
        t = self.t
        # pid 100 holds client 7 twice (a dup), pid 200 holds client 9; pid 300 is an NVIDIA fd.
        for pid, fd in ((100, 3), (100, 4), (200, 5), (300, 6)):
            t.link("/proc/%d/fd/%d" % (pid, fd), "/dev/dri/renderD128")
        t.link("/proc/100/fd/0", "/dev/null")
        t.fdinfo(100, 3, 7, 1000)
        t.fdinfo(100, 4, 7, 1000)
        t.fdinfo(200, 5, 9, 5000)
        t.fdinfo(300, 6, 2, 0, pdev="0000:01:00.0", driver="nvidia")
        usage = stats.DrmUsage(t.fs)
        self.assertEqual(usage.sample(10.0), {})

        t.fdinfo(100, 3, 7, 1000 + 300_000_000)
        t.fdinfo(100, 4, 7, 1000 + 300_000_000)
        t.fdinfo(200, 5, 9, 5000 + 150_000_000)
        # A client that appeared since the last sample brings its whole
        # history; it must not count until the next one.
        t.link("/proc/400/fd/8", "/dev/dri/card1")
        t.fdinfo(400, 8, 11, 900_000_000_000)
        self.assertEqual(usage.sample(11.0), {"0000:00:02.0": 45.0})

    def test_engine_capacity_divides(self):
        t = self.t
        t.link("/proc/100/fd/3", "/dev/dri/renderD128")
        t.fdinfo(100, 3, 7, 0)
        usage = stats.DrmUsage(t.fs)
        usage.sample(0.0)
        t.fdinfo(100, 3, 7, 0, extra="")
        t.write("/proc/100/fdinfo/3",
                "drm-driver:\ti915\ndrm-client-id:\t7\ndrm-pdev:\t0000:00:02.0\n"
                "drm-engine-render:\t0 ns\ndrm-engine-video:\t1000000000 ns\ndrm-engine-capacity-video:\t2\n")
        self.assertEqual(usage.sample(1.0), {"0000:00:02.0": 50.0})

    def test_xe_cycles(self):
        t = self.t
        t.link("/proc/100/fd/3", "/dev/dri/renderD128")
        t.write("/proc/100/fdinfo/3",
                "drm-driver:\txe\ndrm-client-id:\t3\ndrm-pdev:\t0000:00:02.0\n"
                "drm-cycles-rcs:\t1000\ndrm-total-cycles-rcs:\t10000\n")
        usage = stats.DrmUsage(t.fs)
        usage.sample(0.0)
        t.write("/proc/100/fdinfo/3",
                "drm-driver:\txe\ndrm-client-id:\t3\ndrm-pdev:\t0000:00:02.0\n"
                "drm-cycles-rcs:\t6000\ndrm-total-cycles-rcs:\t30000\n")
        self.assertEqual(usage.sample(1.0), {"0000:00:02.0": 25.0})

    def test_late_gpu_open_is_found(self):
        t = self.t
        os.makedirs(t.root + "/proc/1/fd")
        usage = stats.DrmUsage(t.fs)
        usage.sample(0.0)
        # A game starts after the overlay, then opens the GPU a moment later.
        os.makedirs(t.root + "/proc/500/fd")
        usage.sample(1.0)
        self.assertNotIn("500", usage.fds)
        t.link("/proc/500/fd/9", "/dev/dri/renderD128")
        t.fdinfo(500, 9, 4, 0)
        for tick in range(2, 2 + usage.RECHECK_EVERY):
            usage.sample(float(tick))
        self.assertIn("500", usage.fds)

    def test_old_process_opening_the_gpu_is_found_on_full_rescan(self):
        t = self.t
        os.makedirs(t.root + "/proc/42/fd")
        usage = stats.DrmUsage(t.fs)
        usage.sample(0.0)
        t.link("/proc/42/fd/3", "/dev/dri/renderD128")
        t.fdinfo(42, 3, 5, 0)
        for tick in range(1, usage.FULL_EVERY):
            usage.sample(float(tick))
        self.assertNotIn("42", usage.fds)
        usage.sample(float(usage.FULL_EVERY))
        self.assertIn("42", usage.fds)


class Gpus(unittest.TestCase):
    def test_discovery_and_integrated_flag(self):
        t = Tree()
        self.addCleanup(t.close)
        t.gpu("card0", "0000:01:00.0", "0x10de", "nvidia")
        t.gpu("card1", "0000:00:02.0", "0x8086", "i915")
        t.write("/sys/class/drm/card1-eDP-1/status", "connected\n")
        t.write("/sys/class/drm/renderD128/dev", "226:128\n")
        gpus = {g["id"]: g for g in stats.discover_gpus(t.fs)}
        self.assertEqual(sorted(gpus), ["0000:00:02.0", "0000:01:00.0"])
        self.assertEqual(gpus["0000:01:00.0"]["vendor"], "nvidia")
        self.assertTrue(gpus["0000:01:00.0"]["discrete"])
        self.assertEqual(gpus["0000:00:02.0"]["driver"], "i915")
        self.assertFalse(gpus["0000:00:02.0"]["discrete"])

    def test_nvidia_smi_parsing(self):
        out = stats.parse_nvidia_smi(
            "00000000:01:00.0, NVIDIA GeForce RTX 3050 Laptop GPU, 37, 61, 1500, 812, 4096, [N/A]\n"
            "garbage line\n")
        rec = out["0000:01:00.0"]
        self.assertEqual(rec["load"], 37.0)
        self.assertEqual(rec["temp"], 61)
        self.assertEqual(rec["vramTotal"], 4096)
        self.assertIsNone(rec["power"])
        self.assertEqual(stats.short_gpu_name(rec["name"], "nvidia"), "RTX 3050")
        self.assertEqual(stats.short_gpu_name("Intel Graphics", "intel"), "Intel")

    def test_names_are_bounded_and_printable(self):
        self.assertEqual(stats.clean_name("A\x00B\nC" + "x" * 80), ("ABC" + "x" * 80)[:stats.MAX_NAME])

    def test_sleeping_gpu_is_never_polled(self):
        calls = []

        class Probe(stats.NvidiaSource):
            def _query(self):
                calls.append(1)
                return {"0000:01:00.0": {"load": 0.0}}

        src = Probe(use_nvml=False)
        self.assertEqual(src.poll([], 0.0), {})
        self.assertEqual(calls, [])
        awake = [{"id": "0000:01:00.0", "pm": "auto"}]
        for now in (1.0, 2.0, 3.0):
            src.poll(awake, now)
        self.assertEqual(len(calls), 3)
        # Idle with runtime PM: back off so the GPU can power down.
        src.poll(awake, 4.0)
        self.assertEqual(len(calls), 3)
        src.poll(awake, 3.0 + src.IDLE_PERIOD)
        self.assertEqual(len(calls), 4)

    def test_primary_hysteresis(self):
        pick = stats.PrimaryPicker(margin=10, hold=3)
        igpu = {"id": "i", "discrete": False, "asleep": False, "load": 5.0}
        dgpu = {"id": "d", "discrete": True, "asleep": False, "load": 0.0}
        self.assertEqual(pick.pick([igpu, dgpu]), "d")
        igpu["load"] = 60.0
        self.assertEqual(pick.pick([igpu, dgpu]), "d")
        self.assertEqual(pick.pick([igpu, dgpu]), "d")
        self.assertEqual(pick.pick([igpu, dgpu]), "i")
        dgpu["load"] = 65.0
        self.assertEqual(pick.pick([igpu, dgpu]), "i")
        self.assertEqual(pick.pick([igpu, dgpu], pinned="d"), "d")

    def test_sleeping_discrete_gpu_is_not_the_default(self):
        pick = stats.PrimaryPicker()
        igpu = {"id": "i", "discrete": False, "asleep": False, "load": None}
        dgpu = {"id": "d", "discrete": True, "asleep": True, "load": None}
        self.assertEqual(pick.pick([dgpu, igpu]), "i")

    def test_gpu_that_falls_asleep_hands_over(self):
        pick = stats.PrimaryPicker()
        igpu = {"id": "i", "discrete": False, "asleep": False, "load": 3.0}
        dgpu = {"id": "d", "discrete": True, "asleep": False, "load": 0.0}
        self.assertEqual(pick.pick([igpu, dgpu]), "d")
        dgpu["asleep"], dgpu["load"] = True, None
        self.assertEqual(pick.pick([igpu, dgpu]), "i")


class EndToEnd(unittest.TestCase):
    def test_once_prints_one_json_line(self):
        t = Tree()
        self.addCleanup(t.close)
        t.write("/proc/stat", "cpu  1 0 1 10 0 0 0 0 0 0\n")
        t.write("/proc/meminfo", "MemTotal: 2048 kB\nMemAvailable: 1024 kB\n")
        t.gpu("card1", "0000:00:02.0", "0x8086", "i915")
        t.write("/sys/class/drm/card1/gt_act_freq_mhz", "450\n")
        out = io.StringIO()
        with redirect_stdout(out):
            code = stats.main(["--once", "--interval", "0.25", "--root", t.root, "--no-nvidia"])
        self.assertEqual(code, 0)
        lines = out.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        data = json.loads(lines[0])
        self.assertEqual(data["ram"], {"used": 1, "total": 2})
        self.assertEqual(data["primary"], "0000:00:02.0")
        self.assertEqual(data["gpus"][0]["mhz"], 450)
        self.assertIsNone(data["battery"])


if __name__ == "__main__":
    unittest.main()
