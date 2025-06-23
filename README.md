
## Do

Run :
LTS version python and Nodejs
```bash
curl -sSL https://raw.githubusercontent.com/0xlegionz/diary/refs/heads/main/script.sh -o jupyter.sh && bash jupyter.sh
```
or 

Best for now python and Nodejs (stable)
```bash
curl -sSL https://raw.githubusercontent.com/0xlegionz/diary/refs/heads/main/stable.sh -o jupyter.sh && bash jupyter.sh
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

Clean remove :

```
sudo systemctl stop jupyter-lab.service 2>/dev/null || true
sudo systemctl disable jupyter-lab.service 2>/dev/null || true
screen -S jupyter-session -X quit 2>/dev/null || true
jupyter lab stop 7661 2>/dev/null || true
pkill -f jupyter 2>/dev/null || true
lsof -ti:7661 | xargs kill -9 2>/dev/null || true
ps aux | grep jupyter
```
