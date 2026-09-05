import random
import csv
from datetime import date, timedelta

random.seed(42)  # 固定シードで再現性を担保(誰が実行しても同じデータになる)

NUM_TRANSACTIONS = 500
NUM_CUSTOMERS = 50
START_DATE = date(2026, 1, 1)
NUM_DAYS = 60
BRANCHES = ["001", "002", "003", "004", "005"]
TRANSACTION_TYPES = ["振込", "引出", "入金", "振替"]

customers = [f"CUST-{i:05d}" for i in range(1, NUM_CUSTOMERS + 1)]

rows = []
for i in range(1, NUM_TRANSACTIONS + 1):
    txn_id = f"TXN-{i:06d}"
    txn_date = START_DATE + timedelta(days=random.randint(0, NUM_DAYS - 1))
    customer_id = random.choice(customers)
    txn_type = random.choice(TRANSACTION_TYPES)
    if txn_type == "入金":
        amount = random.randint(10000, 3000000)
    elif txn_type == "引出":
        amount = random.randint(1000, 500000)
    else:
        amount = random.randint(1000, 1000000)
    branch = random.choice(BRANCHES)
    rows.append([txn_id, txn_date.isoformat(), customer_id, amount, branch, txn_type])

rows.sort(key=lambda r: (r[1], r[0]))

with open("transactions.csv", "w", newline="", encoding="utf-8") as f:
    writer = csv.writer(f)
    writer.writerow(["transaction_id", "transaction_date", "customer_id", "amount", "branch_code", "transaction_type"])
    writer.writerows(rows)

print(f"{len(rows)}件のダミーデータを transactions.csv に生成しました。")
print(f"期間: {START_DATE} 〜 {START_DATE + timedelta(days=NUM_DAYS-1)}")
print(f"顧客数: {NUM_CUSTOMERS}名")
