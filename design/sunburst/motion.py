import json,os,sys,urllib.request,base64
name=sys.argv[1]; q=sys.argv[2] if len(sys.argv)>2 else "high"
body={"model":"gpt-image-2.6-sunburst","prompt":open(f"motion/prompts/{name}.txt").read(),"size":"512x512","quality":q,"output_format":"gif"}
req=urllib.request.Request("https://api.openai.com/v1/images/generations",data=json.dumps(body).encode(),headers={"Authorization":"Bearer "+os.environ["OPENAI_API_KEY"],"Content-Type":"application/json"})
try: d=json.load(urllib.request.urlopen(req,timeout=600))
except urllib.error.HTTPError as e: print(name,e.code,e.read().decode()[:400]); sys.exit(1)
except Exception as e: print(name,"failed",e); sys.exit(1)
open(f"motion/{name}.gif","wb").write(base64.b64decode(d["data"][0]["b64_json"])); print(name,"ok")
