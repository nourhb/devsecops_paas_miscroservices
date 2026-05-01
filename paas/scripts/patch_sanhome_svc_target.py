import paramiko

s = paramiko.SSHClient()
s.set_missing_host_key_policy(paramiko.AutoAddPolicy())
s.connect("192.168.56.129", username="master", password="master", timeout=30)
_, o, e = s.exec_command(
    """kubectl patch svc -n devsecops-paas paas-sanhome-sanhome --type=json """
    """-p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'""",
    timeout=30,
)
print((o.read() + e.read()).decode())
s.close()
