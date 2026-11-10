# Like motion.py, but Sunburst also sees reference images: our real screen and our dither up close.
import json,os,subprocess,sys,base64
name=sys.argv[1]; refs=sys.argv[2:]
cmd=["curl","-sS","--max-time","600","https://api.openai.com/v1/images/edits","-H","Authorization: Bearer "+os.environ["OPENAI_API_KEY"],
 "-F","model=gpt-image-2.6-sunburst","-F","prompt="+open(f"motion/prompts/{name}.txt").read(),"-F","size=512x512",
 "-F","quality=high","-F","output_format=gif"]+sum([["-F","image[]=@"+r] for r in refs],[])
out=subprocess.run(cmd,capture_output=True,text=True).stdout
try: d=json.loads(out)
except Exception: print(name,"bad response",out[:300]); sys.exit(1)
if "data" not in d: print(name,d.get("error")); sys.exit(1)
open(f"motion/{name}.gif","wb").write(base64.b64decode(d["data"][0]["b64_json"])); print(name,"ok")
