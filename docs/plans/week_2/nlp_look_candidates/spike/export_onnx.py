import torch, os
from transformers import AutoModelForTokenClassification
HERE=os.path.dirname(os.path.abspath(__file__))
m=AutoModelForTokenClassification.from_pretrained(os.path.join(HERE,"ckpt")).eval()
ids=torch.ones(1,16,dtype=torch.long); attn=torch.ones(1,16,dtype=torch.long)
torch.onnx.export(m,(ids,attn),os.path.join(HERE,"lc.onnx"),
  input_names=["input_ids","attention_mask"],output_names=["logits"],
  dynamic_axes={"input_ids":{0:"b",1:"t"},"attention_mask":{0:"b",1:"t"},"logits":{0:"b",1:"t"}},
  opset_version=17, dynamo=False)
print("bytes", os.path.getsize(os.path.join(HERE,"lc.onnx")))
