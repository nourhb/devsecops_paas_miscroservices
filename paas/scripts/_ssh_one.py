import paramiko, sys
c = sys.argv[1]
s = paramiko.SSHClient()
s.set_missing_host_key_policy(paramiko.AutoAddPolicy())
s.connect("192.168.56.129", username="master", password="master", timeout=30)
_, o, e = s.exec_command(c, timeout=60)
print((o.read() + e.read()).decode())
s.close()
