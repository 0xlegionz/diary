
## Do

Run :

```bash
curl -sSL https://raw.githubusercontent.com/0xlegionz/diary/refs/heads/main/script.sh -o jupyter.sh && bash jupyter.sh
```
    


## Error fixing

if error when install some dependency using pip / pip3 :

```
error: externally-managed-environment
```

so you should do :

```
ls /usr/lib/python3.12/EXTERNALLY-MANAGED
mv /usr/lib/python3.12/EXTERNALLY-MANAGED /usr/lib/python3.12/EXTERNALLY-MANAGED.bak
```
