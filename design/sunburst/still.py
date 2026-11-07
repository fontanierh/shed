# One Sunburst still: the prompt plus the shared style, with our own mockup as the style anchor.
import json,os,subprocess,sys,base64
name=sys.argv[1]
prompt=open(f"prompts/{name}.txt").read()+open("prompts/_style.txt").read()
cmd=["curl","-sS","--max-time","600","https://api.openai.com/v1/images/edits","-H","Authorization: Bearer "+os.environ["OPENAI_API_KEY"],
 "-F","model=gpt-image-2.6-sunburst","-F","prompt="+prompt,"-F","size=1536x1024","-F","quality=high","-F","image[]=@anchor.png"]
out=subprocess.run(cmd,capture_output=True,text=True).stdout
try: d=json.loads(out)
except Exception: print(name,"bad response",out[:300]); sys.exit(1)
if "data" not in d: print(name,d.get("error")); sys.exit(1)
open(f"stills/{name}.png","wb").write(base64.b64decode(d["data"][0]["b64_json"]))
print(name,"ok")
