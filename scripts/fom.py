import subprocess
import re
import gzip
import argparse
import zipfile
import json
import os

# This script computes the Figure of Merit (FOM) for a given ASIC design.
# use 'python scripts/fom.py' from the repo directory to run the script

def compute_fom(f_max, cycles, area, power):
    return 1e14 * (f_max / (cycles * area * power))

def get_fmax(gz_path="build/par-rundir/timingReports/riscv_top_postRoute_all.tarpt.gz"):
    try:
        with gzip.open(gz_path, "rt") as f:
            lines = f.readlines()

        slack = None
        required_time = None

        for line in lines:
            if "Slack:=" in line:
                match = re.search(r"Slack:=[\s]+([-\d.]+)", line)
                if match:
                    slack = float(match.group(1))
            if "Required Time:=" in line:
                match = re.search(r"Required Time:=[\s]+([-\d.]+)", line)
                if match:
                    required_time = float(match.group(1))
            if slack is not None and required_time is not None:
                break

        if slack is None or required_time is None:
            raise ValueError("Could not find both Slack and Required Time in the report.")

        period_ns = required_time - slack
        if period_ns <= 0:
            raise ValueError(f"Invalid period: Required Time - Slack = {period_ns}")

        frequency_ghz = 1.0 / period_ns

        return {
            "required_time_ns": required_time,
            "slack_ns": slack,
            "frequency_ghz": frequency_ghz
        }

    except Exception as e:
        raise RuntimeError(f"Failed to process gzipped report: {e}")

def get_area_and_power(script_path="scripts/get_area_and_power.sh"):
    try:
        result = subprocess.run(["bash", script_path], capture_output=True, text=True, check=True)
        output = result.stdout
        lines = output.splitlines()

        # Parse area: find the riscv_top summary line from report_area output
        area = None
        inst_count = None
        for line in lines:
            if "riscv_top" in line:
                parts = line.strip().split()
                if len(parts) >= 2:
                    try:
                        inst_count = int(parts[-2])
                        area = float(parts[-1])
                        break
                    except ValueError:
                        pass

        if area is None:
            raise ValueError("Could not find riscv_top area entry in Innovus output.")

        # Parse power: Total Power line from report_power output
        power = None
        for line in lines:
            match = re.search(r"Total Power:\s+([0-9.]+)", line)
            if match:
                power = float(match.group(1))
                break

        if power is None:
            raise ValueError("Could not find Total Power in Innovus report output.")

        # Optional sanity check: ensure this was actually post-route
        saw_postroute = any("Design Stage: PostRoute" in line for line in lines)
        if not saw_postroute:
            raise RuntimeError(
                "Innovus output did not indicate 'Design Stage: PostRoute'. "
                "Make sure get_area_and_power.tcl reads a post-route checkpoint."
            )

        return {
            "inst_count": inst_count,
            "total_area": area,
            "total_power_mw": power,
        }

    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Script execution failed:\nSTDOUT:\n{e.stdout}\nSTDERR:\n{e.stderr}")
    except Exception as e:
        raise RuntimeError(f"Parsing failed: {e}")

def get_cycles(test_bmark="sum.out"):
    try:
        cmd = ["make", "sim-rtl", "-B", f"test_bmark={test_bmark}"]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        output = result.stdout

        pattern = r"\[ PASSED \]\s+.+? after ([\d_]+) simulation cycles"
        match = re.search(pattern, output)
        if match:
            sim_cycles_str = match.group(1).replace("_", "")
            sim_cycles = int(sim_cycles_str)
            return {
                "passed": True,
                "simulation_cycles": sim_cycles
            }
        else:
            return {
                "passed": False,
                "simulation_cycles": None
            }

    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Simulation failed:\n{e.stdout}\n{e.stderr}")

def dump_to_submission(fom, f_max, cycles, area, power, submission_path):
    res = {
        "score": 1.0,
        "output": f"Success! FOM: {fom}",
        "leaderboard": [
            {"name": "Frequency (MHz)", "value": f_max},
            {"name": "Area", "value": area, "order": "asc"},
            {"name": "Power (mW)", "value": power, "order": "asc"},
            {"name": "Cycles", "value": cycles, "order": "asc"},
            {"name": "FOM", "value": fom},
        ]
    }

    os.makedirs(submission_path, exist_ok=True)

    json_path = os.path.join(submission_path, "results.json")
    zip_path = os.path.join(submission_path, "results.zip")

    with open(json_path, "w") as w:
        json.dump(res, w)

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(json_path, arcname="results.json")

def main():
    parser = argparse.ArgumentParser(description="Compute Figure of Merit (FOM) for ASIC design.")
    parser.add_argument("--cycles", type=int, help="Number of cycles of sum simulation.", default=None)
    parser.add_argument("--submission_path", type=str, help="Path to output submission zip file.", default=".submission")

    args = parser.parse_args()

    if args.cycles is not None:
        cycles = args.cycles
        print(f"Manually specified cycles: {cycles}")
    else:
        print("Running simulation...")
        cycles_data = get_cycles()
        if not cycles_data["passed"]:
            raise RuntimeError("Simulation did not pass successfully.")
        cycles = cycles_data["simulation_cycles"]
        print(f"Simulation cycles: {cycles}")

    print("Getting frequency from post-route timing report...")
    f_max_data = get_fmax()
    if f_max_data["slack_ns"] < 0:
        raise RuntimeError(f"Negative slack: {f_max_data['slack_ns']} ns")
    f_max = f_max_data["frequency_ghz"] * 1000
    print(f"Frequency: {f_max} MHz")

    print("Getting post-route area and power from Innovus...")
    design_data = get_area_and_power()
    area = design_data["total_area"]
    power = design_data["total_power_mw"]
    print(f"Area: {area} um^2")
    print(f"Power: {power} mW")

    if power <= 0:
        raise RuntimeError(f"Invalid power value: {power} mW")

    fom = compute_fom(f_max, cycles, area, power)
    print(f"Figure of Merit (FOM): {fom}")

    dump_to_submission(fom, f_max, cycles, area, power, args.submission_path)

if __name__ == "__main__":
    main()
