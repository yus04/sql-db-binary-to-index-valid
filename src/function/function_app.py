"""SQL Database (dbo.Claims) の変更を SQL トリガーで受け取り、
VARBINARY のファイルデータを Blob として復元し、その他の項目を Blob メタデータとして付与する。"""

from __future__ import annotations

import base64
import json
import logging
import os
from datetime import datetime, timezone
from urllib.parse import quote

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContainerClient, ContentSettings

app = func.FunctionApp()

# SQL トリガーの Operation 値
OPERATION_DELETE = 2

# Blob メタデータの合計サイズ上限 (キー + 値)
METADATA_LIMIT_BYTES = 8 * 1024

# 日本語を含み得る列。Blob メタデータは ASCII のみ許容されるため URL エンコードして格納し、
# AI Search インデクサー側の fieldMappings (urlDecode) で復号する。
TEXT_METADATA_COLUMNS = {
    "ClaimNumber": "claim_number",
    "CustomerName": "customer_name",
    "ProductName": "product_name",
    "LotNumber": "lot_number",
    "ClaimCategory": "claim_category",
    "Severity": "severity",
    "IncidentSummary": "incident_summary",
    "Status": "status",
    "DocumentType": "document_type",
    "FileName": "file_name",
}

# ASCII のみの列はそのまま格納する (日付は ISO 8601 UTC 形式に正規化)
DATE_METADATA_COLUMNS = {
    "ReceivedDate": "received_date",
    "IncidentDate": "incident_date",
}

_container_client: ContainerClient | None = None


def get_container_client() -> ContainerClient:
    global _container_client
    if _container_client is None:
        # Azure 上では AZURE_CLIENT_ID で指定したユーザー割り当てマネージド ID が使われる
        service = BlobServiceClient(
            account_url=os.environ["DOCUMENT_STORAGE_ACCOUNT_URL"],
            credential=DefaultAzureCredential(),
        )
        _container_client = service.get_container_client(os.environ["DOCUMENT_CONTAINER_NAME"])
    return _container_client


@app.function_name(name="ClaimsToBlob")
@app.sql_trigger(
    arg_name="changes",
    table_name="dbo.Claims",
    connection_string_setting="SqlConnectionString",
)
def claims_to_blob(changes: str) -> None:
    container = get_container_client()

    for change in json.loads(changes):
        item = change["Item"]
        if change["Operation"] == OPERATION_DELETE:
            # 削除時は主キーしか渡されないため Blob 名を特定できない。本検証では対象外とする。
            logging.info("Skip delete operation. ClaimId=%s", item.get("ClaimId"))
            continue

        blob_name = build_blob_name(item)
        file_bytes = decode_file_data(item["FileData"])
        metadata = build_metadata(item)

        container.upload_blob(
            name=blob_name,
            data=file_bytes,
            overwrite=True,
            metadata=metadata,
            content_settings=ContentSettings(
                content_type=item.get("ContentType") or "application/octet-stream"
            ),
        )
        logging.info(
            "Uploaded blob. ClaimId=%s blob=%s size=%d metadata_keys=%s",
            item["ClaimId"], blob_name, len(file_bytes), sorted(metadata),
        )


def build_blob_name(item: dict) -> str:
    return f"{item['ClaimNumber']}/{item['ClaimId']}_{item['FileName']}"


def decode_file_data(value: str | list[int]) -> bytes:
    # SQL トリガーは VARBINARY を JSON 上で Base64 文字列として渡す
    if isinstance(value, list):
        return bytes(value)
    return base64.b64decode(value)


def build_metadata(item: dict) -> dict[str, str]:
    metadata: dict[str, str] = {"claim_id": str(item["ClaimId"])}

    for column, key in DATE_METADATA_COLUMNS.items():
        if item.get(column):
            metadata[key] = to_utc_iso8601(item[column])

    for column, key in TEXT_METADATA_COLUMNS.items():
        if item.get(column) is not None:
            metadata[key] = encode_text(item[column])

    # 上限超過時は最も長くなり得る発生事象 (incident_summary) を切り詰める
    summary = item.get("IncidentSummary") or ""
    truncated = False
    while metadata_size(metadata) > METADATA_LIMIT_BYTES and summary:
        summary = summary[: int(len(summary) * 0.9)]
        metadata["incident_summary"] = encode_text(summary + "…")
        truncated = True
    if truncated:
        logging.warning("Metadata exceeded %d bytes. Truncated incident_summary. ClaimId=%s",
                        METADATA_LIMIT_BYTES, item["ClaimId"])

    return metadata


def encode_text(value: object) -> str:
    return quote(str(value), safe="")


def to_utc_iso8601(value: str) -> str:
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def metadata_size(metadata: dict[str, str]) -> int:
    return sum(len(k) + len(v) for k, v in metadata.items())
