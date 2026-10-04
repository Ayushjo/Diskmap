import math, random, wave, array
SR=44100; DUR=62.5; N=int(SR*DUR)
L=array.array('f',[0.0])*N; R=array.array('f',[0.0])*N
bpm=100; beat=60/bpm; bar=4*beat
def hz(m): return 440*2**((m-69)/12)
# Fmaj7, Am7, Dm9, Bbmaj7 (MIDI), 2 bars each
chords=[[53,57,60,64,69],[57,60,64,67,72],[50,57,60,64,65],[46,53,57,62,65]]
def add(buf,i,v):
    if 0<=i<N: buf[i]+=v
# pad
seg=2*bar
for ci in range(int(DUR/seg)+1):
    ch=chords[ci%4]; t0=ci*seg
    for k,m in enumerate(ch):
        f=hz(m); start=int(t0*SR); length=int((seg+0.6)*SR)
        pan=0.3+0.4*(k/(len(ch)-1))
        for j in range(0,length):
            i=start+j
            if i>=N: break
            t=j/SR
            env=min(1,t/1.2)*min(1,(seg+0.6-t)/0.8)
            ph=2*math.pi*f*t
            s=(math.sin(ph)+0.35*math.sin(2*ph+0.3)+0.12*math.sin(3*ph)+0.5*math.sin(ph*1.004))*env*0.028
            L[i]+=s*(1-pan); R[i]+=s*pan
# arp pluck on 8ths from bar 1
step=beat/2; t=bar*0.5; n=0
while t<DUR-2.5:
    ch=chords[int(t/seg)%4]; pat=[0,2,4,2,1,3,4,3]
    m=ch[pat[n%8]]+12; f=hz(m); start=int(t*SR); pan=0.5+0.3*math.sin(n*0.7)
    vol=0.05 if t>3.4 else 0.03
    for j in range(int(0.9*SR)):
        i=start+j
        if i>=N: break
        tt=j/SR; env=math.exp(-tt*6)*min(1,tt/0.004)
        s=(math.sin(2*math.pi*f*tt)+0.25*math.sin(4*math.pi*f*tt))*env*vol
        L[i]+=s*(1-pan); R[i]+=s*pan
    t+=step; n+=1
# kick on 1 and 3 after the title, hats on offbeats after 10s
random.seed(3)
b=0
while b*beat<DUR-2.0:
    t=b*beat
    if t>=3.6 and b%2==0 and not (50.5<t<53.6):
        start=int(t*SR); ph=0
        for j in range(int(0.35*SR)):
            tt=j/SR; f=45+80*math.exp(-tt*28); ph+=2*math.pi*f/SR
            s=math.sin(ph)*math.exp(-tt*9)*0.32
            add(L,start+j,s); add(R,start+j,s)
    if t>=10 and not (50.5<t<53.6):
        start=int((t+beat/2)*SR); prev=0
        for j in range(int(0.06*SR)):
            x=random.uniform(-1,1); hp=x-prev; prev=x
            s=hp*math.exp(-j/SR*70)*0.025
            add(L,start+j,s*0.8); add(R,start+j,s)
    b+=1
# master: fade in/out, soft clip
out=array.array('h')
for i in range(N):
    t=i/SR; g=min(1,t/0.8)*min(1,(DUR-t)/3.0)
    for v in (L[i],R[i]):
        out.append(int(32767*math.tanh(v*g*1.6)*0.85))
w=wave.open('music.wav','wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(out.tobytes()); w.close()
print('ok')
