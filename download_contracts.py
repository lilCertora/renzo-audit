import requests
import json
import os
import time

API_KEY = "QDPM5ZXQ8F2P9WV7ST415W1QM1UQYTTVGX"
BASE_URL = "https://api.etherscan.io/v2/api"
OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))

ADDRESSES = [
    "0x5efc9D10E42FB517456f4ac41EB5e2eBe42C8918",
    "0xf2F305D14DCD8aaef887E0428B3c9534795D0d60",
    "0xbf5495Efe5DB9ce00f80364C8B423567e58d2110",
    "0xbAf5f3A05BD7Af6f3a0BBA207803bf77e2657c8F",
    "0x5a12796f7e7EBbbc8a402667d266d2e65A814042",
    "0x74a09653A083691711cF8215a6ab074BB4e99ef5",
    "0x22eEC85ba6a5cD97eAd4728eA1c69e1D9c6fa778",
    "0x4994EFc62101A9e3F885d872514c2dC7b3235849",
]


def fetch_source(address):
    params = {
        "chainid": "1",
        "module": "contract",
        "action": "getsourcecode",
        "address": address,
        "apikey": API_KEY,
    }
    resp = requests.get(BASE_URL, params=params)
    resp.raise_for_status()
    data = resp.json()
    if data["status"] != "1" or not data["result"]:
        print(f"  [ERROR] API returned: {data.get('message', 'unknown')} - {data.get('result', '')}")
        return None
    return data["result"][0]


def save_sources(contract_info, folder):
    os.makedirs(folder, exist_ok=True)
    source = contract_info["SourceCode"]
    name = contract_info["ContractName"]

    if source.startswith("{{"):
        source = source[1:-1]

    try:
        parsed = json.loads(source)
        sources = parsed.get("sources", parsed)
        if isinstance(sources, dict):
            for filepath, content in sources.items():
                if isinstance(content, dict):
                    code = content.get("content", "")
                else:
                    code = content
                out_path = os.path.join(folder, filepath.replace("../", "").lstrip("/"))
                os.makedirs(os.path.dirname(out_path), exist_ok=True)
                with open(out_path, "w") as f:
                    f.write(code)
                print(f"    {os.path.relpath(out_path, OUTPUT_DIR)}")
            return
    except (json.JSONDecodeError, AttributeError):
        pass

    out_path = os.path.join(folder, f"{name}.sol")
    with open(out_path, "w") as f:
        f.write(source)
    print(f"    {os.path.relpath(out_path, OUTPUT_DIR)}")


def get_implementation_address(contract_info):
    impl = contract_info.get("Implementation", "")
    if impl and impl != "0x" and impl != "0x0000000000000000000000000000000000000000":
        return impl
    return None


def main():
    for address in ADDRESSES:
        print(f"\n{'='*60}")
        print(f"Fetching {address}...")
        info = fetch_source(address)
        if not info:
            continue

        contract_name = info["ContractName"] or address
        impl_addr = get_implementation_address(info)
        is_proxy = info.get("Proxy") == "1" or bool(impl_addr)

        print(f"  Contract: {contract_name} (Proxy: {is_proxy})")

        if is_proxy and impl_addr:
            print(f"  Implementation: {impl_addr}")
            time.sleep(0.25)
            impl_info = fetch_source(impl_addr)
            if impl_info:
                impl_name = impl_info["ContractName"] or "Implementation"
                print(f"  Implementation contract: {impl_name}")
                folder = os.path.join(OUTPUT_DIR, impl_name)
                save_sources(impl_info, folder)
            else:
                print(f"  [WARN] Could not fetch implementation, saving proxy source")
                folder = os.path.join(OUTPUT_DIR, contract_name)
                save_sources(info, folder)
        else:
            folder = os.path.join(OUTPUT_DIR, contract_name)
            save_sources(info, folder)

        time.sleep(0.25)

    print(f"\n{'='*60}")
    print("Done!")


if __name__ == "__main__":
    main()
