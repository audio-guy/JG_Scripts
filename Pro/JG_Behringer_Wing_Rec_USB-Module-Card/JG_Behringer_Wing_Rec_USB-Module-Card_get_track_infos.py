import socket, time, os, json, sys

try:
    from pythonosc.dispatcher import Dispatcher
    from pythonosc.osc_server import OSCUDPServer
    from pythonosc.osc_message_builder import OscMessageBuilder
except ImportError:
    print("\nERROR: python-osc is missing! Please run in terminal: python3 -m pip install python-osc")
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, "wing_config.txt")
JSON_FILE = os.path.join(SCRIPT_DIR, "wing_routing.json")

WING_IP    = "192.168.8.3"
WING_PORT  = 2223
BATCH_SIZE = 1000
INTERFACE  = "USB" 
OUT_COUNT  = 48    
NAME_MODE  = "CH"
FORCE_HW_COLORS = False

WING_COLORS = {
    0: (60, 60, 60), 1: (50, 50, 200), 2: (0, 100, 255), 3: (128, 0, 255), 
    4: (0, 200, 255), 5: (0, 200, 0), 6: (128, 255, 0), 7: (255, 255, 0), 
    8: (200, 100, 0), 9: (255, 0, 0), 10: (255, 128, 128), 11: (255, 0, 128), 
    12: (200, 100, 255), 13: (255, 180, 0), 14: (100, 150, 255), 15: (255, 140, 0),
    16: (0, 180, 150), 17: (120, 120, 120), 18: (230, 230, 230)
}

HW_FIXED_COLORS = {
    "A": (0, 100, 255), "B": (0, 200, 0), "C": (128, 0, 255), "LCL": (0, 180, 150),
    "MOD": (255, 128, 0), "CRD": (200, 200, 200), "USB": (200, 200, 200),
    "AUX": (255, 255, 0), "AES": (255, 0, 255), "OSC": (0, 255, 255),
    "SC": (0, 150, 255), "PLAY": (100, 255, 100), "USR": (255, 100, 100),
    "MAIN": (255, 50, 50), "BUS": (255, 150, 0), "MTX": (255, 100, 200)
}

def load_config():
    global WING_IP, INTERFACE, OUT_COUNT, NAME_MODE, FORCE_HW_COLORS
    if not os.path.exists(CONFIG_FILE): return
    with open(CONFIG_FILE, "r") as f:
        for line in f:
            key, *val = line.strip().split("=")
            if not val: continue
            v = val[0]
            if key == "IP": WING_IP = v
            if key == "INTERFACE": 
                INTERFACE = v
                OUT_COUNT = 64 if v in ("MOD", "CRD") else 48
            if key == "NAME_MODE": NAME_MODE = v
            if key == "FORCE_HW_COLORS": FORCE_HW_COLORS = (v == "1")

def norm(g):
    s = str(g).upper().replace("-", "").replace(" ", "").replace("_", "")
    if "AES50" in s:
        for char in "ABC":
            if char in s: return char
    if s in ("LOCAL", "LOC", "LCL"): return "LCL"
    if s in ("MOD", "MODULE", "DANTE"): return "MOD"
    if s in ("AUX", "AUXIN"): return "AUX"
    if s in ("AESEBU", "AES"): return "AES"
    if s in ("OSC", "OSCILLATOR"): return "OSC"
    if s in ("SC", "STAGECONNECT", "STCONNECT"): return "SC"
    if s in ("USB", "USBAUDIO"): return "USB"
    if s in ("PLAY", "USBPLAYER"): return "PLAY"
    if s in ("USR", "USER", "USERSIGNAL"): return "USR"
    if s in ("CRD", "CARD"): return "CRD"
    return s

def query_reliable(addrs, timeout=0.3, attempts=4):
    if not addrs: return {}
    res = {a: None for a in addrs}
    pending = set(addrs)
    def h(addr, *args):
        if addr in pending:
            res[addr] = str(args[0]) if args else ""
            pending.discard(addr)
    d = Dispatcher(); d.set_default_handler(h)
    server = OSCUDPServer(("0.0.0.0", 0), d); server.timeout = 0.002
    sock = server.socket
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1048576)
    
    for i in range(0, len(addrs), BATCH_SIZE):
        batch = addrs[i:i+BATCH_SIZE]
        for attempt in range(attempts):
            bp = pending.intersection(batch)
            if not bp: break
            for a in bp: sock.sendto(OscMessageBuilder(address=a).build().dgram, (WING_IP, WING_PORT))
            end = time.time() + timeout
            while time.time() < end: server.handle_request()
    server.server_close()
    return res

def fetch_wing():
    start_time = time.time()
    print(f"High-Speed polling WING @ {WING_IP} (Interface: {INTERFACE})...")
    
    probe_addrs = []
    for f in ["1", "01", "001"]:
        probe_addrs += [f"/ch/{f}/name", f"/src/{f}/name", f"/src/{f}/in/grp", f"/src/{f}/in/conn/grp"]
    
    r_probe = query_reliable(probe_addrs, timeout=0.15, attempts=4)
    
    ch_fmt = "{i}"
    if r_probe.get("/ch/01/name") is not None: ch_fmt = "{i:02d}"
    
    src_fmt = "{i}"
    if r_probe.get("/src/001/name") is not None: src_fmt = "{i:03d}"
    elif r_probe.get("/src/01/name") is not None: src_fmt = "{i:02d}"
    
    src_route_grp = "in/grp"
    src_route_idx = "in/in"
    if r_probe.get(f"/src/{src_fmt.format(i=1)}/in/conn/grp") is not None:
        src_route_grp, src_route_idx = "in/conn/grp", "in/conn/in"

    addrs1 = []
    for s in range(1, OUT_COUNT + 1):
        addrs1 += [f"/io/out/{INTERFACE}/{s}/grp", f"/io/out/{INTERFACE}/{s}/in"]
        
    for i in range(1, 41):
        for f_str in [str(i), f"{i:02d}"]:
            addrs1 += [f"/ch/{f_str}/name", f"/ch/{f_str}/col", f"/ch/{f_str}/led", f"/ch/{f_str}/light", f"/ch/{f_str}/in/conn/grp", f"/ch/{f_str}/in/conn/in", f"/ch/{f_str}/in/conn/altgrp", f"/ch/{f_str}/in/conn/altin"]
    for i in range(1, 9):
        for f_str in [str(i), f"{i:02d}"]:
            addrs1 += [f"/aux/{f_str}/name", f"/aux/{f_str}/col", f"/aux/{f_str}/led", f"/aux/{f_str}/light", f"/aux/{f_str}/in/conn/grp", f"/aux/{f_str}/in/conn/in", f"/aux/{f_str}/in/conn/altgrp", f"/aux/{f_str}/in/conn/altin"]
            
    for b in ["main", "bus", "mtx"]:
        count = 4 if b=="main" else (16 if b=="bus" else 8)
        for i in range(1, count+1):
            for f_str in [str(i), f"{i:02d}"]:
                addrs1 += [f"/{b}/{f_str}/name", f"/{b}/{f_str}/col", f"/{b}/{f_str}/led", f"/{b}/{f_str}/light"]
                
    r1 = query_reliable(addrs1, timeout=0.3, attempts=4)

    hw_refs = set()
    for s in range(1, OUT_COUNT + 1):
        raw_g = (r1.get(f"/io/out/{INTERFACE}/{s}/grp") or "").strip()
        n_str = (r1.get(f"/io/out/{INTERFACE}/{s}/in") or "").strip()
        if raw_g and n_str and raw_g not in ("MAIN", "BUS", "MTX", "CH", "AUX", "OFF"):
            try: hw_refs.add((raw_g, int(n_str)))
            except: pass

    for prefix, count in [("ch", 40), ("aux", 8)]:
        for i in range(1, count + 1):
            for f_str in [str(i), f"{i:02d}"]:
                raw_g = (r1.get(f"/{prefix}/{f_str}/in/conn/grp") or "").strip()
                n_str = (r1.get(f"/{prefix}/{f_str}/in/conn/in") or "").strip()
                if raw_g and n_str and raw_g not in ("MAIN", "BUS", "MTX", "CH", "AUX", "OFF"):
                    try: hw_refs.add((raw_g, int(n_str)))
                    except: pass
                # Also collect alt source refs
                alt_g = (r1.get(f"/{prefix}/{f_str}/in/conn/altgrp") or "").strip()
                alt_n = (r1.get(f"/{prefix}/{f_str}/in/conn/altin") or "").strip()
                if alt_g and alt_n and alt_g not in ("MAIN", "BUS", "MTX", "CH", "AUX", "OFF"):
                    try: hw_refs.add((alt_g, int(alt_n)))
                    except: pass

    addrs2 = []
    for (raw_g, n) in hw_refs:
        addrs2 += [f"/io/in/{raw_g}/{n}/name", f"/io/in/{raw_g}/{n}/col", f"/io/in/{raw_g}/{n}/led", f"/io/in/{raw_g}/{n}/light", f"/io/in/{raw_g}/{n}/mode"]
        
    r2 = query_reliable(addrs2, timeout=0.15, attempts=4) if addrs2 else {}
    
    r = {**r1, **r2}
    src_modes = {(norm(g), n): r.get(f"/io/in/{g}/{n}/mode", "M") for (g, n) in hw_refs}

    def is_off(val):
        return val in ("0", "0.0", "OFF", "false", "False", "0.000000")

    def gather_sources():
        src_data = {}
        for (raw_g, n) in hw_refs:
            s_name = (r.get(f"/io/in/{raw_g}/{n}/name") or "").strip()
            s_col = r.get(f"/io/in/{raw_g}/{n}/col") or "0"
            s_light = str(r.get(f"/io/in/{raw_g}/{n}/led") or r.get(f"/io/in/{raw_g}/{n}/light") or "1")
            try: src_data[(norm(raw_g), int(n))] = (s_name, int(s_col), is_off(s_light))
            except: pass
        return src_data

    def gather_channels():
        ch_data = {}
        for prefix, count in [("aux", 8), ("ch", 40)]:
            for i in range(count, 0, -1):
                idx_str = f"{i:02d}"
                c_name = (r.get(f"/{prefix}/{i}/name") or "").strip() or (r.get(f"/{prefix}/{idx_str}/name") or "").strip()
                c_col = r.get(f"/{prefix}/{i}/col") or r.get(f"/{prefix}/{idx_str}/col") or "0"
                c_light = str(r.get(f"/{prefix}/{i}/led") or r.get(f"/{prefix}/{idx_str}/led") or r.get(f"/{prefix}/{i}/light") or r.get(f"/{prefix}/{idx_str}/light") or "1")
                
                c_grp = norm(r.get(f"/{prefix}/{i}/in/conn/grp") or r.get(f"/{prefix}/{idx_str}/in/conn/grp") or "")
                c_in = r.get(f"/{prefix}/{i}/in/conn/in") or r.get(f"/{prefix}/{idx_str}/in/conn/in") or ""
                
                try:
                    idx_in = int(c_in)
                    if c_grp: ch_data[(c_grp, idx_in)] = (c_name, int(c_col), is_off(c_light))
                except: continue
        return ch_data

    src_to_hw = gather_sources()
    ch_to_hw = gather_channels()

    # Alt source mapping: (hw_grp, hw_in) → (ch_name + " ALT", col, is_off)
    # Priority: earlier channel wins, main source always wins over alt source
    def gather_alt_channels():
        alt_data = {}
        for prefix, count in [("aux", 8), ("ch", 40)]:
            for i in range(count, 0, -1):
                idx_str = f"{i:02d}"
                c_name = (r.get(f"/{prefix}/{i}/name") or "").strip() or (r.get(f"/{prefix}/{idx_str}/name") or "").strip()
                c_col = r.get(f"/{prefix}/{i}/col") or r.get(f"/{prefix}/{idx_str}/col") or "0"
                c_light = str(r.get(f"/{prefix}/{i}/led") or r.get(f"/{prefix}/{idx_str}/led") or r.get(f"/{prefix}/{i}/light") or r.get(f"/{prefix}/{idx_str}/light") or "1")

                a_grp = norm(r.get(f"/{prefix}/{i}/in/conn/altgrp") or r.get(f"/{prefix}/{idx_str}/in/conn/altgrp") or "")
                a_in = r.get(f"/{prefix}/{i}/in/conn/altin") or r.get(f"/{prefix}/{idx_str}/in/conn/altin") or ""

                try:
                    idx_in = int(a_in)
                    if a_grp and a_grp != "OFF":
                        alt_data[(a_grp, idx_in)] = (c_name, int(c_col), is_off(c_light))
                except: continue
        return alt_data

    alt_ch_to_hw = gather_alt_channels()

    tracks = []
    for s in range(1, OUT_COUNT + 1):
        raw_grp = (r.get(f"/io/out/{INTERFACE}/{s}/grp") or "").strip()
        u_grp = norm(raw_grp)
        try: u_in = int(r.get(f"/io/out/{INTERFACE}/{s}/in") or str(s))
        except: u_in = s

        is_empty_routing = (u_grp == "OFF" or u_grp == "")

        is_direct_ch = False
        ch_direct_name = ""
        ch_direct_col = 0
        ch_direct_off = False
        hw_grp, hw_in = u_grp, u_in
        
        if u_grp in ("CH", "AUX"):
            is_direct_ch = True
            prefix = u_grp.lower()
            ch_direct_name = (r.get(f"/{prefix}/{u_in}/name") or "").strip() or (r.get(f"/{prefix}/{u_in:02d}/name") or "").strip()
            
            c_col = r.get(f"/{prefix}/{u_in}/col") or r.get(f"/{prefix}/{u_in:02d}/col") or "0"
            try: ch_direct_col = int(c_col)
            except: pass
            
            c_light = str(r.get(f"/{prefix}/{u_in}/led") or r.get(f"/{prefix}/{u_in:02d}/led") or r.get(f"/{prefix}/{u_in}/light") or r.get(f"/{prefix}/{u_in:02d}/light") or "1")
            ch_direct_off = is_off(c_light)
            
            h_grp = norm(r.get(f"/{prefix}/{u_in}/in/conn/grp") or r.get(f"/{prefix}/{u_in:02d}/in/conn/grp") or "")
            h_in = r.get(f"/{prefix}/{u_in}/in/conn/in") or r.get(f"/{prefix}/{u_in:02d}/in/conn/in") or ""
            if h_grp and h_in:
                hw_grp = h_grp
                try: hw_in = int(h_in)
                except: pass

        name, col = "", 0
        force_uncolored = False
        ch_str, src_str, hw_str = "-", "-", "-"
        
        if is_empty_routing:
            name = f"(INPUT {s} NOT ROUTED)"
            col = 0
            force_uncolored = True
        elif hw_grp in ("MAIN", "BUS", "MTX"):
            m_idx = (hw_in - 1) // 2 + 1
            actual_name = (r.get(f"/{hw_grp.lower()}/{m_idx}/name") or r.get(f"/{hw_grp.lower()}/{m_idx:02d}/name") or "").strip()
            
            col_raw = r.get(f"/{hw_grp.lower()}/{m_idx}/col") or r.get(f"/{hw_grp.lower()}/{m_idx:02d}/col") or "0"
            try: col = int(col_raw)
            except: col = 0
            
            ch_str = actual_name if actual_name else "-"
            src_str = "-"
            hw_str = f"{hw_grp} {m_idx}" + (" L" if hw_in % 2 != 0 else " R")
            
            if NAME_MODE == "CH":
                if actual_name: name = actual_name + (" L" if hw_in % 2 != 0 else " R")
                else: name = "" 
                
                light_val = str(r.get(f"/{hw_grp.lower()}/{m_idx}/led") or r.get(f"/{hw_grp.lower()}/{m_idx:02d}/led") or r.get(f"/{hw_grp.lower()}/{m_idx}/light") or r.get(f"/{hw_grp.lower()}/{m_idx:02d}/light") or "1")
                if is_off(light_val): force_uncolored = True
            else: 
                name = f"{hw_grp} {m_idx}" + (" L" if hw_in % 2 != 0 else " R")
                
        else:
            hw_key = (hw_grp, hw_in)
            
            if is_direct_ch and ch_direct_name: ch_str = ch_direct_name
            elif hw_key in ch_to_hw and ch_to_hw[hw_key][0]: ch_str = ch_to_hw[hw_key][0]
            elif hw_key in alt_ch_to_hw and alt_ch_to_hw[hw_key][0]: ch_str = alt_ch_to_hw[hw_key][0] + " ALT"
            
            if hw_key in src_to_hw and src_to_hw[hw_key][0]: src_str = src_to_hw[hw_key][0]
            hw_str = f"{hw_grp} {hw_in}"
            
            if NAME_MODE == "CH":
                if is_direct_ch:
                    name, col, force_uncolored = ch_direct_name, ch_direct_col, ch_direct_off
                elif hw_key in ch_to_hw: 
                    name, col, force_uncolored = ch_to_hw[hw_key]
                elif hw_key in alt_ch_to_hw:
                    alt_name, alt_col, alt_off = alt_ch_to_hw[hw_key]
                    name = (alt_name + " ALT") if alt_name else ""
                    col = alt_col
                    force_uncolored = alt_off
            elif NAME_MODE == "SRC":
                if hw_key in src_to_hw:
                    name, col, _ = src_to_hw[hw_key]
            elif NAME_MODE == "HW":
                name, col = f"{hw_grp} {hw_in}", 0
            
            if not name and NAME_MODE == "HW":
                name = f"{hw_grp} {hw_in}"
        
        use_hw_color = FORCE_HW_COLORS or (NAME_MODE == "HW")
        if NAME_MODE == "SRC" and hw_grp in ("MAIN", "BUS", "MTX"):
            use_hw_color = True
            
        if use_hw_color and hw_grp in HW_FIXED_COLORS and not is_empty_routing:
            rgb = HW_FIXED_COLORS[hw_grp]
        elif force_uncolored:
            rgb = WING_COLORS[0]
        else:
            rgb = WING_COLORS.get(col, WING_COLORS[0])
            
        tracks.append({
            "slot": s, "name": name, "color_r": rgb[0], "color_g": rgb[1], "color_b": rgb[2],
            "norm_grp": hw_grp, "in_num": hw_in, 
            "ch_name": ch_str, "src_name": src_str, "hw_name": hw_str,
            "reaper_input": s - 1, "stereo_L": False, "stereo_R": False,
            "is_empty_routing": is_empty_routing
        })

    for i in range(len(tracks)-1):
        if tracks[i].get("is_empty_routing") or tracks[i]["stereo_R"]: continue 
        t1, t2 = tracks[i], tracks[i+1]
        if t2.get("is_empty_routing"): continue

        is_stereo = False
        
        if t1["name"] and t1["name"].endswith(" L") and t2["name"] == t1["name"].replace(" L", " R"):
            is_stereo = True
        elif t1["norm_grp"] == t2["norm_grp"]:
            if t1["norm_grp"] in ("MAIN", "BUS", "MTX"):
                if t1["in_num"] % 2 == 1 and t2["in_num"] == t1["in_num"] + 1:
                    is_stereo = True
            else:
                if t1["in_num"] % 2 == 1 and t2["in_num"] == t1["in_num"] + 1:
                    if src_modes.get((t1["norm_grp"], t1["in_num"])) == "ST": 
                        is_stereo = True

        if is_stereo:
            t1["stereo_L"], t2["stereo_R"] = True, True
            t1["reaper_input"] = 1024 + (t1["slot"] - 1)
            
            if t1["name"]:
                clean_name = t1["name"]
                if clean_name == f"{t1['norm_grp']} {t1['in_num']}":
                    clean_name = f"{t1['norm_grp']} {t1['in_num']}-{t1['in_num']+1}"
                else:
                    if clean_name.endswith(" L"): clean_name = clean_name[:-2]
                    elif clean_name.endswith("L"): clean_name = clean_name[:-1]
                t1["name"] = clean_name.strip()
                
            for k in ["ch_name", "src_name", "hw_name"]:
                val = t1.get(k, "-")
                if val != "-":
                    if val == f"{t1.get('norm_grp')} {t1.get('in_num')}":
                        val = f"{t1['norm_grp']} {t1['in_num']}-{t1['in_num']+1}"
                    else:
                        if val.endswith(" L"): val = val[:-2]
                        elif val.endswith("L"): val = val[:-1]
                    t1[k] = val.strip()

    for t in tracks:
        t.pop("norm_grp", None); t.pop("in_num", None)

    duration = time.time() - start_time
    print(f"Finished in {duration:.2f}s.")
    return tracks

if __name__ == "__main__":
    load_config()
    tracks = fetch_wing()
    with open(JSON_FILE, "w", encoding="utf-8") as f:
        json.dump(tracks, f, indent=2)
