from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import subprocess
from pathlib import Path

import requests
from web3 import Web3


ROOT = Path(__file__).resolve().parents[1]
LOCAL_OZ_ROOT = Path(r"G:\onchainclaw\lib\openzeppelin-contracts\contracts")
DEFAULT_RPC_URL = "https://mainnet-rpc.rnk.dev"
DEFAULT_PRIVATE_KEY_ENV = "ONCHAINCLAW_BSC_PRIVATE_KEY"
DEFAULT_OZ_TAG = "v5.1.0"
DEFAULT_SOLC_VERSION = "0.8.28"
DEFAULT_CONTRACT_PATH = "aa-v2/contracts/reactive/baseline/BaselineStopTakeProfitReactive.sol"
DEFAULT_CONTRACT_NAME = "BaselineStopTakeProfitReactive"


def _load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        if key and key not in os.environ:
            os.environ[key.strip()] = value.strip().strip('"').strip("'")


def _fetch_oz_source(tag: str, relpath: str) -> str:
    local_path = LOCAL_OZ_ROOT / relpath
    if local_path.exists():
        return local_path.read_text(encoding="utf-8")
    url = f"https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/{tag}/contracts/{relpath}"
    response = requests.get(url, timeout=30)
    response.raise_for_status()
    return response.text


def build_source_map(entry_key: str, *, oz_tag: str) -> dict[str, dict[str, str]]:
    cache: dict[str, dict[str, str]] = {}

    def fetch(key: str) -> None:
        if key in cache:
            return
        if key.startswith("@openzeppelin/contracts/"):
            rel = key[len("@openzeppelin/contracts/") :]
            text = _fetch_oz_source(oz_tag, rel)
        else:
            text = (ROOT / key).read_text(encoding="utf-8")
        cache[key] = {"content": text}
        for match in re.finditer(r'import\s+(?:[^"\']+from\s+)?["\']([^"\']+)["\'];', text):
            imported = match.group(1)
            if imported.startswith("."):
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(key), imported))
                fetch(resolved)
            else:
                fetch(imported)

    fetch(entry_key)
    return cache


def compile_contract(entry_key: str, contract_name: str, *, oz_tag: str) -> tuple[list[dict], str]:
    std = {
        "language": "Solidity",
        "sources": build_source_map(entry_key, oz_tag=oz_tag),
        "settings": {
            "optimizer": {"enabled": True, "runs": 200},
            "viaIR": True,
            "outputSelection": {"*": {"*": ["abi", "evm.bytecode.object"]}},
        },
    }
    proc = subprocess.run(
        ["npx.cmd", f"solc@{DEFAULT_SOLC_VERSION}", "--standard-json"],
        input=json.dumps(std),
        text=True,
        capture_output=True,
        cwd=str(ROOT),
        timeout=240,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr[-1000:])
    start = proc.stdout.find("{")
    output = json.loads(proc.stdout[start:])
    errors = [err for err in output.get("errors", []) if err.get("severity") == "error"]
    if errors:
        raise RuntimeError(errors[0].get("formattedMessage", "compile failed"))
    contract = output["contracts"][entry_key][contract_name]
    return contract["abi"], contract["evm"]["bytecode"]["object"]


def main() -> None:
    parser = argparse.ArgumentParser(description="Deploy the official baseline reactive monitor on RNK.")
    parser.add_argument("--rpc-url", default=DEFAULT_RPC_URL)
    parser.add_argument("--private-key-env", default=DEFAULT_PRIVATE_KEY_ENV)
    parser.add_argument("--owner-address", required=True)
    parser.add_argument("--callback-address", required=True)
    parser.add_argument("--oz-tag", default=DEFAULT_OZ_TAG)
    parser.add_argument("--gas-price-wei", default=0, type=int)
    parser.add_argument("--gas-limit", default=0, type=int)
    parser.add_argument("--value-wei", default=0, type=int)
    args = parser.parse_args()

    _load_env_file(ROOT / ".env")
    private_key = os.getenv(args.private_key_env, "").strip()
    if not private_key:
        raise ValueError(f"missing private key env {args.private_key_env}")

    abi, bytecode = compile_contract(DEFAULT_CONTRACT_PATH, DEFAULT_CONTRACT_NAME, oz_tag=args.oz_tag)
    session = requests.Session()
    session.trust_env = False
    w3 = Web3(Web3.HTTPProvider(args.rpc_url, request_kwargs={"timeout": 20}, session=session))
    account = w3.eth.account.from_key(private_key)
    contract = w3.eth.contract(abi=abi, bytecode="0x" + bytecode)
    deploy_tx = contract.constructor(
        Web3.to_checksum_address(args.owner_address),
        Web3.to_checksum_address(args.callback_address),
    ).build_transaction(
        {
            "chainId": int(w3.eth.chain_id),
            "from": account.address,
            "nonce": w3.eth.get_transaction_count(account.address, "pending"),
            "gasPrice": int(args.gas_price_wei or w3.eth.gas_price),
            "value": int(args.value_wei),
        }
    )
    deploy_tx["gas"] = int(args.gas_limit or w3.eth.estimate_gas(deploy_tx))
    signed = w3.eth.account.sign_transaction(deploy_tx, private_key=private_key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=240)
    if receipt.status != 1:
        raise RuntimeError("baseline reactive deployment failed on-chain")
    print(json.dumps({
        "contract_address": receipt.contractAddress,
        "tx_hash": tx_hash.hex(),
        "gas_used": int(receipt.gasUsed),
        "owner_address": args.owner_address,
        "callback_address": args.callback_address,
        "value_wei": int(args.value_wei),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
