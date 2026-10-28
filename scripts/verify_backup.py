# -*- coding: utf-8 -*-
"""校验备份数据库内容"""
import sqlite3

con = sqlite3.connect(r'D:\Desktop\workspace\MyProject\HMDots\backups\fitdot-20261012-084746.db')
cur = con.cursor()
tables = [r[0] for r in cur.execute("select name from sqlite_master where type='table'")]
print('tables:', tables)
for t in tables:
    if t.startswith('sqlite_'):
        continue
    n = cur.execute('select count(*) from ' + t).fetchone()[0]
    print(t, n, 'rows')
