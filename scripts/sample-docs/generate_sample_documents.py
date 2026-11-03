"""検証用のクレーム情報と報告資料・添付資料 (PDF / Word / Excel) を生成する。

出力:
  sample-data/documents/*.pdf|docx|xlsx  ... VARBINARY として SQL Database に登録するファイル
  sample-data/claims.json                ... Register-SampleData.ps1 が読み込むレコード定義

実行例:
  pip install -r scripts/sample-docs/requirements.txt
  python scripts/sample-docs/generate_sample_documents.py
"""

from __future__ import annotations

import json
from pathlib import Path

from docx import Document
from docx.oxml.ns import qn
from docx.shared import Pt
from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "sample-data" / "documents"
CLAIMS_JSON = ROOT / "sample-data" / "claims.json"

AUTHOR = "サンプル精機株式会社 品質保証部"
PDF_FONT = "HeiseiKakuGo-W5"
DOCX_FONT = "Yu Gothic"

CONTENT_TYPES = {
    ".pdf": "application/pdf",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
}

# ---------------------------------------------------------------------------
# クレーム (SQL Database の 1 レコード = 1 ファイル)
# ---------------------------------------------------------------------------
CLAIM_1 = {
    "ClaimNumber": "CLM-2026-0001",
    "ReceivedDate": "2026-09-02",
    "CustomerName": "東和食品工業株式会社 千葉工場",
    "ProductName": "産業用ギアポンプ GP-450",
    "LotNumber": "L2408-117",
    "ClaimCategory": "品質不良",
    "Severity": "高",
    "IncidentDate": "2026-08-28",
    "IncidentSummary": (
        "液糖移送ラインで使用中のギアポンプ GP-450 において、稼働開始から約320時間で吐出圧力が"
        "定格0.80MPaから0.55MPaまで低下し、運転中に周期的な異音が発生した。"
        "分解点検の結果、ドライブギア歯面に異常摩耗を確認した。"
    ),
    "Status": "対策実施中",
}

CLAIM_2 = {
    "ClaimNumber": "CLM-2026-0002",
    "ReceivedDate": "2026-09-12",
    "CustomerName": "北陸ケミカル株式会社 富山事業所",
    "ProductName": "電磁流量計 EMF-200 (口径50A)",
    "LotNumber": "L2405-032",
    "ClaimCategory": "計測異常",
    "Severity": "中",
    "IncidentDate": "2026-09-10",
    "IncidentSummary": (
        "排水処理設備に設置した電磁流量計 EMF-200 の指示値が、基準流量計との比較で約8%高く表示される。"
        "現地での零点調整後も偏差が解消せず、中和用薬液の注入量が過剰となっている。"
    ),
    "Status": "原因調査中",
}

CLAIM_3 = {
    "ClaimNumber": "CLM-2026-0003",
    "ReceivedDate": "2026-07-16",
    "CustomerName": "南海物流株式会社 堺配送センター",
    "ProductName": "搬送設備用制御盤 CP-7000",
    "LotNumber": "L2407-088",
    "ClaimCategory": "製造不備",
    "Severity": "高",
    "IncidentDate": "2026-07-15",
    "IncidentSummary": (
        "据付後の試運転において、非常停止押しボタンを操作してもコンベアが停止しない事象が発生した。"
        "調査の結果、非常停止回路の端子台で配線が図面と異なる端子に接続されていた。"
    ),
    "Status": "完了",
}

# ---------------------------------------------------------------------------
# 文書コンテンツ (PDF / Word 共通のブロック構造)
#   ("title", str) / ("meta", [[k, v], ...]) / ("h", str) / ("p", str) / ("table", [[...], ...])
# ---------------------------------------------------------------------------
REPORT_GP450 = [
    ("title", "不具合調査報告書"),
    ("meta", [
        ["報告書番号", "QA-R-2026-0147"],
        ["クレーム番号", "CLM-2026-0001"],
        ["顧客名", "東和食品工業株式会社 千葉工場 御中"],
        ["対象製品", "産業用ギアポンプ GP-450 (製造ロット L2408-117)"],
        ["発行日", "2026年9月18日"],
        ["作成", "サンプル精機株式会社 品質保証部 山田 太郎"],
    ]),
    ("h", "1. 概要"),
    ("p", "2026年8月28日、貴社千葉工場の液糖移送ラインにおいて、弊社製ギアポンプ GP-450 の吐出圧力低下および"
          "運転中の異音が発生しました。本報告書は、返却品の調査結果、推定原因、ならびに暫定対策と恒久対策について"
          "ご報告するものです。ご迷惑をおかけしましたことを深くお詫び申し上げます。"),
    ("h", "2. 発生状況"),
    ("p", "当該ポンプは2026年7月中旬に据付され、1日あたり約16時間の連続運転で使用されていました。運転開始から"
          "約320時間が経過した時点で、吐出圧力が定格0.80MPaから0.55MPaまで低下し、同時に回転周期と同期した"
          "金属的な異音が確認されました。貴社保全担当者様によりポンプは停止され、予備機へ切り替えられています。"
          "移送液は粘度約200mPa・sの液糖で、液温は45℃前後と、カタログ記載の使用条件の範囲内でした。"),
    ("h", "3. 調査内容"),
    ("p", "返却品を弊社工場にて分解し、外観観察、寸法測定、表面硬度測定、および材質分析を実施しました。"
          "外観観察では、ドライブギアの歯面全周にわたり段付き状の摩耗が認められ、ドリブンギアにも軽度の"
          "かじり痕が見られました。ケーシング内面およびサイドプレートには異物の噛み込み痕は認められず、"
          "異物混入による摩耗の可能性は低いと判断しました。"),
    ("table", [
        ["測定項目", "規格値", "返却品", "同ロット在庫品 (平均)", "判定"],
        ["ドライブギア 表面硬度", "HRC 58〜62", "HRC 52", "HRC 53.4", "不合格"],
        ["ドライブギア 歯厚", "8.00 ±0.02 mm", "7.82 mm", "8.01 mm", "不合格"],
        ["ドリブンギア 表面硬度", "HRC 58〜62", "HRC 59", "HRC 59.6", "合格"],
        ["材質 (SCM415)", "JIS G 4053 準拠", "適合", "適合", "合格"],
    ]),
    ("p", "上表のとおり、返却品および同ロットの在庫品5台のドライブギアにおいて、表面硬度が規格値を下回って"
          "いることが判明しました。一方、材質分析の結果は規格に適合しており、素材起因ではないと判断しました。"),
    ("h", "4. 推定原因"),
    ("p", "ドライブギアの浸炭焼入れ工程の記録を確認したところ、2026年8月第1週に熱処理炉No.2の温度制御用"
          "熱電対が劣化しており、炉内温度が設定値より約30℃低い状態で処理されていたことが判明しました。"
          "このため浸炭深さが不足し、表面硬度が規格を満たさないギアが製造されたものと推定します。"
          "また、当該期間の抜取検査は1ロットあたり1個であり、硬度不足を検出できませんでした。"),
    ("h", "5. 暫定対策"),
    ("p", "(1) 貴社に納入した同ロット品3台について、対策済みギアを組み込んだ代替品と2026年9月25日までに交換いたします。"
          "(2) 弊社在庫の同ロット品はすべて出荷停止とし、ドライブギアの全数硬度検査を実施しています。"
          "(3) 同時期に熱処理炉No.2で処理した他製品についても、トレーサビリティ記録をもとに影響範囲を調査中です。"),
    ("h", "6. 恒久対策"),
    ("p", "(1) 熱処理炉の熱電対を定期交換部品に指定し、交換周期を6か月とします。"
          "(2) 炉内温度を独立した監視用熱電対で二重計測し、偏差が10℃を超えた場合に警報を発する仕組みを導入します。"
          "(3) 浸炭焼入れ後の硬度抜取検査を1ロットあたり1個から5個に変更し、検査記録をロット番号に紐づけて保管します。"
          "これらの対策は2026年10月末までに完了する予定です。"),
    ("h", "7. 今後の予定"),
    ("p", "代替品の交換完了後、1か月間の運転データ(吐出圧力・振動値)を貴社と共有させていただき、効果を確認いたします。"
          "恒久対策の実施状況については、2026年11月に改めてご報告いたします。"),
]

SURVEY_EMF200 = [
    ("title", "現地調査報告書"),
    ("meta", [
        ["報告書番号", "FS-2026-0089"],
        ["クレーム番号", "CLM-2026-0002"],
        ["顧客名", "北陸ケミカル株式会社 富山事業所 御中"],
        ["対象製品", "電磁流量計 EMF-200 口径50A (製造ロット L2405-032, 製造番号 E2405-0321)"],
        ["調査日", "2026年9月16日"],
        ["調査者", "サンプル精機株式会社 フィールドサービス課 佐藤 花子 / 鈴木 一郎"],
    ]),
    ("h", "1. 調査目的"),
    ("p", "排水処理設備の中和工程に設置された電磁流量計 EMF-200 の指示値が、基準流量計に対して約8%高く"
          "表示されるとのご連絡を受け、現地にて設置状況および計測状態を確認し、原因を特定することを目的として"
          "調査を実施しました。"),
    ("h", "2. 設置状況の確認"),
    ("p", "流量計は排水ピットからの送液配管(SUS304、50A)に水平設置されていました。取扱説明書では上流側に"
          "口径の5倍(5D)以上、下流側に2D以上の直管長を確保することを推奨していますが、現地では上流側の"
          "直管長が約2Dしかなく、直前に90度エルボと仕切弁が設置されていました。また、樹脂ライニング配管との"
          "接続部において、接地リングが取り付けられているものの接地線が端子に接続されていないことを確認しました。"),
    ("table", [
        ["確認項目", "推奨条件", "現地の状況", "評価"],
        ["上流側直管長", "5D (250mm) 以上", "約2D (100mm)", "要改善"],
        ["下流側直管長", "2D (100mm) 以上", "約6D (300mm)", "良好"],
        ["接地リングの接地", "接地端子へ接続", "未接続", "要改善"],
        ["満水状態", "常時満水", "満水 (気泡なし)", "良好"],
        ["電源電圧", "AC100V ±10%", "AC101V", "良好"],
    ]),
    ("h", "3. 計測確認"),
    ("p", "持ち込んだクランプオン式超音波流量計を基準器として、流量を4点変化させて比較測定を行いました。"
          "いずれの流量点においても EMF-200 の指示値が基準器より6.9〜8.4%高い結果となり、流量が小さいほど"
          "偏差が大きくなる傾向が見られました。零点調整を再実施しましたが、偏差に有意な変化はありませんでした。"
          "詳細な測定値は添付の校正試験成績書をご参照ください。"),
    ("h", "4. 考察"),
    ("p", "接地線が未接続の状態では、液体と流量計本体の電位が安定せず、電極間に重畳する外来ノイズが流量信号"
          "として誤検出されることがあります。小流量域ほど偏差が大きいという傾向は、ノイズ起因の誤差の特徴と"
          "一致します。加えて、上流側直管長の不足により偏流が生じ、流速分布の乱れが指示値を押し上げている"
          "可能性があります。現時点では、接地不良が主要因、偏流が副次的要因であると推定しています。"),
    ("h", "5. 推奨事項"),
    ("p", "(1) 接地リングの接地線を接地端子に接続し、接地抵抗100Ω以下を確保してください(弊社にて実施可能です)。"
          "(2) 次回の定期修繕時に、流量計の設置位置を上流側直管長5D以上が確保できる位置へ移設することを推奨します。"
          "(3) 移設までの暫定措置として、流量計の変換器に補正係数0.93を設定し、薬液注入量の過剰を抑制します。"),
    ("h", "6. 次回予定"),
    ("p", "2026年9月30日に接地工事を実施し、同日に再度比較測定を行います。その結果を踏まえて、補正係数の要否と"
          "移設計画について改めてご相談させていただきます。"),
]

CALIBRATION_EMF200 = [
    ("title", "校正試験成績書"),
    ("meta", [
        ["成績書番号", "CAL-2026-0412"],
        ["クレーム番号", "CLM-2026-0002"],
        ["対象機器", "電磁流量計 EMF-200 口径50A / 製造番号 E2405-0321"],
        ["試験日", "2026年9月16日 (現地) / 2026年5月20日 (工場出荷時)"],
        ["基準器", "クランプオン式超音波流量計 UF-10 (校正有効期限 2027年3月)"],
        ["試験者", "サンプル精機株式会社 フィールドサービス課 佐藤 花子"],
    ]),
    ("h", "1. 試験条件"),
    ("p", "測定流体は中和前の排水(導電率約850μS/cm、液温28℃)です。各流量点で3分間の安定待ちの後、"
          "60秒間の平均値を記録しました。流量レンジは0〜20m3/hに設定されています。"),
    ("h", "2. 現地試験結果"),
    ("table", [
        ["流量点", "基準器 (m3/h)", "EMF-200 指示値 (m3/h)", "誤差 (%)", "許容差", "判定"],
        ["25%", "5.02", "5.44", "+8.4", "±1.0%", "不合格"],
        ["50%", "10.05", "10.83", "+7.8", "±1.0%", "不合格"],
        ["75%", "14.98", "16.08", "+7.3", "±1.0%", "不合格"],
        ["100%", "19.96", "21.34", "+6.9", "±1.0%", "不合格"],
    ]),
    ("h", "3. 工場出荷時試験結果 (参考)"),
    ("table", [
        ["流量点", "基準 (m3/h)", "指示値 (m3/h)", "誤差 (%)", "判定"],
        ["25%", "5.00", "5.02", "+0.4", "合格"],
        ["50%", "10.00", "10.03", "+0.3", "合格"],
        ["75%", "15.00", "14.97", "-0.2", "合格"],
        ["100%", "20.00", "20.04", "+0.2", "合格"],
    ]),
    ("h", "4. 所見"),
    ("p", "工場出荷時の試験では全流量点で許容差±1.0%以内であり、変換器および検出器の性能に異常は認められません。"
          "現地試験では全流量点で+6.9〜+8.4%の正方向の偏差が生じており、設置環境(接地不良および上流直管長不足)に"
          "起因する誤差と判断します。接地工事の実施後に再試験を行い、本成績書を更新いたします。"),
]

CORRECTIVE_CP7000 = [
    ("title", "是正処置報告書"),
    ("meta", [
        ["報告書番号", "CA-2026-0031"],
        ["クレーム番号", "CLM-2026-0003"],
        ["顧客名", "南海物流株式会社 堺配送センター 御中"],
        ["対象製品", "搬送設備用制御盤 CP-7000 (製造ロット L2407-088, 盤番号 CP7-0088-02)"],
        ["発行日", "2026年8月5日"],
        ["作成", "サンプル精機株式会社 制御システム部 高橋 誠 / 品質保証部 山田 太郎"],
    ]),
    ("h", "1. 不適合内容"),
    ("p", "2026年7月15日、貴社堺配送センターにおける仕分けコンベアの試運転中に、非常停止押しボタン(EMG-3)を操作しても"
          "コンベアが停止しない事象が発生しました。現地で配線を確認したところ、制御盤内端子台TB-4において、"
          "非常停止回路の配線が図面上の端子番号41-42ではなく43-44に接続されており、安全リレーの入力回路が"
          "短絡された状態となっていました。人的被害および設備損傷はありませんでした。"),
    ("h", "2. 影響範囲"),
    ("p", "同一ロットで製造した制御盤は4面あり、すべてについて非常停止回路の配線を確認しました。誤配線は当該盤"
          "(CP7-0088-02)の1面のみで、他の3面は図面どおりに配線されていることを確認済みです。また、同じ図面改訂版を"
          "使用した他顧客向けの制御盤は現時点で出荷されていません。"),
    ("h", "3. 発生原因"),
    ("p", "なぜなぜ分析の結果、以下の原因が特定されました。(1) 2026年6月に配線図が改訂され、非常停止回路の端子割付が"
          "変更されたが、製造現場への改訂周知が口頭のみで行われ、作業者が旧版の図面を参照して配線した。"
          "(2) 配線作業後の自主チェックリストに、非常停止回路の導通確認項目が含まれていなかった。"),
    ("h", "4. 流出原因"),
    ("p", "出荷前検査において、非常停止回路の機能試験は「顧客先試運転時に実施」として省略されていました。"
          "安全機能に関わる回路について、工場内で機能を確認する手順が定められていなかったことが流出の原因です。"),
    ("h", "5. 是正処置"),
    ("p", "当該盤の配線を図面どおりに修正し、2026年7月17日に貴社立会いのもとで非常停止機能の動作確認を実施しました。"
          "全8箇所の非常停止押しボタンについて、操作から0.3秒以内にコンベアが停止することを確認しています。"),
    ("h", "6. 再発防止策"),
    ("table", [
        ["No.", "対策内容", "担当", "完了日"],
        ["1", "図面改訂時は旧版を回収し、改訂内容を文書で通知して作業者の確認署名を取得する", "制御システム部", "2026/07/31"],
        ["2", "配線チェックリストに安全回路(非常停止・安全扉)の導通確認項目を追加する", "製造課", "2026/07/25"],
        ["3", "出荷前検査に安全機能の機能試験を必須項目として追加する", "品質保証部", "2026/07/31"],
        ["4", "配線作業者向けに安全回路の重要性に関する教育を実施する", "製造課", "2026/08/04"],
    ]),
    ("h", "7. 効果確認"),
    ("p", "対策実施後に製造した制御盤6面について、改訂後のチェックリストおよび出荷前機能試験を適用し、"
          "安全回路の不適合がゼロであることを確認しました。今後3か月間は品質保証部が出荷前検査に立ち会い、"
          "対策の定着状況を監視します。以上をもって本件の是正処置を完了とさせていただきます。"),
]


# ---------------------------------------------------------------------------
# Excel コンテンツ
# ---------------------------------------------------------------------------
def build_gp450_measurement(path: Path) -> None:
    wb = Workbook()
    ws = wb.active
    ws.title = "測定結果"
    _write_sheet(ws, "GP-450 ドライブギア 測定結果 (クレーム番号 CLM-2026-0001)", [
        ["試料", "製造番号", "表面硬度 (HRC)", "歯厚 (mm)", "歯幅 (mm)", "浸炭深さ (mm)", "判定", "備考"],
        ["返却品", "G4508-1172", 52.0, 7.82, 30.01, 0.42, "不合格", "歯面に段付き摩耗あり"],
        ["在庫品 1", "G4508-1175", 53.1, 8.01, 30.00, 0.45, "不合格", "硬度不足"],
        ["在庫品 2", "G4508-1176", 53.8, 8.00, 29.99, 0.47, "不合格", "硬度不足"],
        ["在庫品 3", "G4508-1179", 52.9, 8.02, 30.01, 0.44, "不合格", "硬度不足"],
        ["在庫品 4", "G4508-1181", 54.0, 8.01, 30.00, 0.48, "不合格", "硬度不足"],
        ["在庫品 5", "G4508-1184", 53.2, 8.00, 30.02, 0.45, "不合格", "硬度不足"],
        ["規格", "-", "58〜62", "8.00 ±0.02", "30.00 ±0.03", "0.8〜1.2", "-", "図面 GP450-D-012 Rev.C"],
    ], [12, 14, 15, 12, 12, 15, 10, 26])

    ws2 = wb.create_sheet("圧力推移")
    _write_sheet(ws2, "顧客先運転データ (吐出圧力の推移)", [
        ["累積運転時間 (h)", "吐出圧力 (MPa)", "振動値 (mm/s)", "記事"],
        [0, 0.80, 1.2, "据付完了・運転開始"],
        [50, 0.80, 1.3, ""],
        [100, 0.79, 1.4, ""],
        [150, 0.77, 1.8, ""],
        [200, 0.74, 2.4, "振動値が上昇傾向"],
        [250, 0.69, 3.1, ""],
        [300, 0.61, 4.5, "異音の発生を確認"],
        [320, 0.55, 5.8, "運転停止・予備機へ切替"],
    ], [18, 16, 16, 30])

    ws3 = wb.create_sheet("所見")
    notes = [
        "【測定者所見】",
        "返却品および同ロット在庫品5台のドライブギアは、いずれも表面硬度が規格下限 HRC58 を下回っている。",
        "浸炭深さも規格 0.8〜1.2mm に対して 0.42〜0.48mm と浅く、浸炭焼入れ条件の不足が示唆される。",
        "熱処理炉No.2の温度記録では、2026年8月第1週に炉内温度が設定値 930℃ に対し約 900℃ で推移していた。",
        "運転データでは累積200時間付近から振動値が上昇し、摩耗の進行とともに吐出圧力が低下している。",
        "ドリブンギアおよびケーシングに異物噛み込みの痕跡はなく、使用条件にも問題は見られない。",
        "以上より、ドライブギアの熱処理不良による早期摩耗が本不具合の主原因と判断する。",
        "",
        "測定日: 2026年9月10日〜9月12日 / 測定者: 品質保証部 検査課 中村 健",
    ]
    for i, line in enumerate(notes, start=1):
        ws3.cell(row=i, column=1, value=line)
    ws3.column_dimensions["A"].width = 110

    _set_xlsx_props(wb, "GP-450 測定データ (CLM-2026-0001)")
    wb.save(path)


def build_cp7000_checklist(path: Path) -> None:
    wb = Workbook()
    ws = wb.active
    ws.title = "点検結果"
    _write_sheet(ws, "CP-7000 安全回路 配線点検チェックリスト (盤番号 CP7-0088-02)", [
        ["No.", "回路", "端子台", "図面上の接続先", "実配線 (是正前)", "判定 (是正前)", "実配線 (是正後)", "判定 (是正後)", "備考"],
        [1, "非常停止 EMG-1", "TB-4", "11-12", "11-12", "OK", "11-12", "OK", ""],
        [2, "非常停止 EMG-2", "TB-4", "21-22", "21-22", "OK", "21-22", "OK", ""],
        [3, "非常停止 EMG-3", "TB-4", "41-42", "43-44", "NG", "41-42", "OK", "旧版図面の端子割付で配線"],
        [4, "非常停止 EMG-4", "TB-4", "51-52", "51-52", "OK", "51-52", "OK", ""],
        [5, "非常停止 EMG-5", "TB-5", "11-12", "11-12", "OK", "11-12", "OK", ""],
        [6, "非常停止 EMG-6", "TB-5", "21-22", "21-22", "OK", "21-22", "OK", ""],
        [7, "非常停止 EMG-7", "TB-5", "31-32", "31-32", "OK", "31-32", "OK", ""],
        [8, "非常停止 EMG-8", "TB-5", "41-42", "41-42", "OK", "41-42", "OK", ""],
        [9, "安全扉 SD-1", "TB-6", "11-12", "11-12", "OK", "11-12", "OK", ""],
        [10, "安全扉 SD-2", "TB-6", "21-22", "21-22", "OK", "21-22", "OK", ""],
        [11, "安全リレー入力 SR-1", "TB-7", "S11-S12", "S11-S12", "OK", "S11-S12", "OK", "EMG-3 誤配線により入力が短絡状態"],
    ], [6, 20, 10, 16, 16, 14, 16, 14, 34])

    ws2 = wb.create_sheet("是正計画")
    _write_sheet(ws2, "是正処置・再発防止計画", [
        ["No.", "区分", "対策内容", "担当部署", "期限", "状況"],
        [1, "是正", "EMG-3 の配線を図面どおり TB-4 41-42 に修正し、非常停止機能を立会い確認する", "制御システム部", "2026/07/17", "完了"],
        [2, "再発防止", "図面改訂時の旧版回収と文書通知・確認署名の運用を開始する", "制御システム部", "2026/07/31", "完了"],
        [3, "再発防止", "配線チェックリストに安全回路の導通確認項目を追加する", "製造課", "2026/07/25", "完了"],
        [4, "再発防止", "出荷前検査に安全機能の機能試験を必須項目として追加する", "品質保証部", "2026/07/31", "完了"],
        [5, "再発防止", "配線作業者 12 名に安全回路に関する教育を実施する", "製造課", "2026/08/04", "完了"],
        [6, "効果確認", "対策後に製造した制御盤 6 面で安全回路の不適合ゼロを確認する", "品質保証部", "2026/08/31", "完了"],
    ], [6, 12, 70, 18, 14, 10])

    _set_xlsx_props(wb, "CP-7000 配線点検チェックリスト (CLM-2026-0003)")
    wb.save(path)


def _write_sheet(ws, title: str, rows: list[list], widths: list[int]) -> None:
    ws.cell(row=1, column=1, value=title).font = Font(bold=True, size=13)
    header_fill = PatternFill("solid", fgColor="DDEBF7")
    for r, row in enumerate(rows, start=3):
        for c, value in enumerate(row, start=1):
            cell = ws.cell(row=r, column=c, value=value)
            cell.alignment = Alignment(wrap_text=True, vertical="top")
            if r == 3:
                cell.font = Font(bold=True)
                cell.fill = header_fill
    for i, width in enumerate(widths, start=1):
        ws.column_dimensions[ws.cell(row=3, column=i).column_letter].width = width


def _set_xlsx_props(wb: Workbook, title: str) -> None:
    wb.properties.title = title
    wb.properties.creator = AUTHOR


# ---------------------------------------------------------------------------
# PDF / Word レンダラ
# ---------------------------------------------------------------------------
def render_pdf(blocks: list, path: Path) -> None:
    pdfmetrics.registerFont(UnicodeCIDFont(PDF_FONT))
    base = ParagraphStyle("base", fontName=PDF_FONT, fontSize=10, leading=16, wordWrap="CJK")
    title_style = ParagraphStyle("title", parent=base, fontSize=18, leading=26, alignment=1, spaceAfter=8)
    heading_style = ParagraphStyle("heading", parent=base, fontSize=12, leading=18, spaceBefore=10, spaceAfter=4)
    cell_style = ParagraphStyle("cell", parent=base, fontSize=9, leading=13)

    title = next(text for kind, text in blocks if kind == "title")
    doc = SimpleDocTemplate(str(path), pagesize=A4, title=title, author=AUTHOR,
                            leftMargin=20 * mm, rightMargin=20 * mm, topMargin=18 * mm, bottomMargin=18 * mm)
    story = []
    for kind, content in blocks:
        if kind == "title":
            story.append(Paragraph(content, title_style))
        elif kind == "h":
            story.append(Paragraph(content, heading_style))
        elif kind == "p":
            story.append(Paragraph(content, base))
        elif kind in ("meta", "table"):
            data = [[Paragraph(str(v), cell_style) for v in row] for row in content]
            table = Table(data, colWidths=[40 * mm, 130 * mm] if kind == "meta" else None, hAlign="LEFT")
            style = [("GRID", (0, 0), (-1, -1), 0.5, colors.grey), ("VALIGN", (0, 0), (-1, -1), "TOP")]
            if kind == "meta":
                style.append(("BACKGROUND", (0, 0), (0, -1), colors.HexColor("#EEF3FA")))
            else:
                style.append(("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#DDEBF7")))
            table.setStyle(TableStyle(style))
            story.extend([table, Spacer(1, 4 * mm)])
    doc.build(story)


def render_docx(blocks: list, path: Path) -> None:
    doc = Document()
    for style_name in ("Normal", "Title", "Heading 1"):
        style = doc.styles[style_name]
        style.font.name = DOCX_FONT
        style.element.get_or_add_rPr().get_or_add_rFonts().set(qn("w:eastAsia"), DOCX_FONT)
    doc.styles["Normal"].font.size = Pt(10.5)

    for kind, content in blocks:
        if kind == "title":
            doc.add_heading(content, level=0)
            doc.core_properties.title = content
        elif kind == "h":
            doc.add_heading(content, level=1)
        elif kind == "p":
            doc.add_paragraph(content)
        elif kind in ("meta", "table"):
            table = doc.add_table(rows=len(content), cols=len(content[0]), style="Table Grid")
            for r, row in enumerate(content):
                for c, value in enumerate(row):
                    table.cell(r, c).text = str(value)
            doc.add_paragraph()
    doc.core_properties.author = AUTHOR
    doc.save(str(path))


# ---------------------------------------------------------------------------
def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    documents = [
        (CLAIM_1, "報告資料", "不具合調査報告書_CLM-2026-0001.pdf", lambda p: render_pdf(REPORT_GP450, p)),
        (CLAIM_1, "添付資料", "測定データ_CLM-2026-0001.xlsx", build_gp450_measurement),
        (CLAIM_2, "報告資料", "現地調査報告書_CLM-2026-0002.docx", lambda p: render_docx(SURVEY_EMF200, p)),
        (CLAIM_2, "添付資料", "校正試験成績書_CLM-2026-0002.pdf", lambda p: render_pdf(CALIBRATION_EMF200, p)),
        (CLAIM_3, "報告資料", "是正処置報告書_CLM-2026-0003.docx", lambda p: render_docx(CORRECTIVE_CP7000, p)),
        (CLAIM_3, "添付資料", "配線点検チェックリスト_CLM-2026-0003.xlsx", build_cp7000_checklist),
    ]

    records = []
    for claim, document_type, file_name, build in documents:
        path = OUT_DIR / file_name
        build(path)
        records.append({
            **claim,
            "DocumentType": document_type,
            "FileName": file_name,
            "ContentType": CONTENT_TYPES[path.suffix],
        })
        print(f"generated: {path.relative_to(ROOT)} ({path.stat().st_size:,} bytes)")

    CLAIMS_JSON.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"generated: {CLAIMS_JSON.relative_to(ROOT)} ({len(records)} records)")


if __name__ == "__main__":
    main()
