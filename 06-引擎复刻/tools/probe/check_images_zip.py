import zipfile, sys
p = r"D:/Program Files (x86)/Steam/steamapps/common/Don't Starve Together/data/databundles/images.zip"
z = zipfile.ZipFile(p)
names = z.namelist()
print("总条目:", len(names))
hits = [n for n in names if "inventoryimage" in n.lower()]
print("inventoryimages 命中:", len(hits))
for h in hits[:30]:
    print("   ", h)
print("--- 抽样前 10 个条目 ---")
for n in names[:10]:
    print("   ", n)
print("--- xml 总数 ---")
print(sum(1 for n in names if n.lower().endswith(".xml")))
