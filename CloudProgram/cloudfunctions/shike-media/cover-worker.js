/**
 * 【文件职责】封面转换 worker（在 worker 线程中运行）：用 jpeg-js 解码原图（长边 ≤1600px），按区域平均缩放到长边 480px，以质量 78 重新编码为 JPEG。
 */
'use strict';
const {parentPort,workerData}=require('node:worker_threads');
const jpeg=require('jpeg-js');
try {
 const source=jpeg.decode(Buffer.from(workerData),{useTArray:true,formatAsRGBA:true,tolerantDecoding:false,maxResolutionInMP:3,maxMemoryUsageInMB:64});
 if(source.width<1||source.height<1||Math.max(source.width,source.height)>1600)throw new Error('Invalid source dimensions');
 const scale=Math.min(1,480/Math.max(source.width,source.height)),width=Math.max(1,Math.round(source.width*scale)),height=Math.max(1,Math.round(source.height*scale));
 const data=new Uint8Array(width*height*4);
 // 区域平均缩放可以完整保留长截图的内容，并避免最近邻缩放产生的锯齿。
 for(let y=0;y<height;y++)for(let x=0;x<width;x++){
   const x0=Math.floor(x*source.width/width),x1=Math.max(x0+1,Math.ceil((x+1)*source.width/width));
   const y0=Math.floor(y*source.height/height),y1=Math.max(y0+1,Math.ceil((y+1)*source.height/height));
   const sums=[0,0,0];let count=0;
   for(let yy=y0;yy<Math.min(y1,source.height);yy++)for(let xx=x0;xx<Math.min(x1,source.width);xx++){
     const i=(yy*source.width+xx)*4;for(let c=0;c<3;c++)sums[c]+=source.data[i+c];count++;
   }
   const to=(y*width+x)*4;for(let c=0;c<3;c++)data[to+c]=Math.round(sums[c]/count);data[to+3]=255;
 }
 const encoded=jpeg.encode({data,width,height},78).data;
 parentPort.postMessage({bytes:encoded,width,height});
}catch(_){parentPort.postMessage({error:'COVER_CONVERSION_FAILED'});}
