import zipfile
p = r"D:/Program Files (x86)/Steam/steamapps/common/Don't Starve Together/data/databundles/images.zip"
z = zipfile.ZipFile(p)
for name in ["images/inventoryimages1.xml", "images/inventoryimages.xml"]:
    data = z.read(name)
    print("=" * 70)
    print(name, " 字节:", len(data))
    print("=" * 70)
    txt = data.decode("utf-8", "replace")
    print(txt[:900])
    print("...")
    print("Element 出现次数:", txt.count("<Element"))
    print("总长:", len(txt))
