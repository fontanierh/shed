# Sunburst redoes a real screenshot of the app: same layout and words, cleaned up and made beautiful in our style.
import json,os,subprocess,sys,base64
name, shot, notes = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
size = "1024x1536" if "phone" in name else "1536x1024"
prompt = ("Image 1 is a real screenshot of our app Shed. Redraw it as the polished, final design: KEEP the same screen, the same layout "
 "regions and the same text, labels and data exactly as written in image 1 (do not invent features or rename things), but fix every "
 "rough edge: consistent spacing on an 8pt grid, aligned baselines, clear hierarchy, balanced density, refined glass cards, crisp icons, "
 "beautiful empty states, and the background beam composed so it frames the content instead of fighting it. Image 2 is the style "
 "reference: match its visual language. " + notes + "\n\n" + open("prompts/_style.txt").read().split("This is a UI component reference")[0]
 + "This is a single full app screen, not a reference sheet: no captions, no annotations.")
cmd=["curl","-sS","--max-time","600","https://api.openai.com/v1/images/edits","-H","Authorization: Bearer "+os.environ["OPENAI_API_KEY"],
 "-F","model=gpt-image-2.6-sunburst","-F","prompt="+prompt,"-F","size="+size,"-F","quality=high",
 "-F","image[]=@"+shot,"-F","image[]=@anchor.png"]
out=subprocess.run(cmd,capture_output=True,text=True).stdout
try: d=json.loads(out)
except Exception: print(name,"bad response",out[:300]); sys.exit(1)
if "data" not in d: print(name,d.get("error")); sys.exit(1)
open(f"redo/out/{name}.png","wb").write(base64.b64decode(d["data"][0]["b64_json"]))
print(name,"ok")
