import { spawn } from 'node:child_process';
import { once } from 'node:events';

export function server(binary, plan, prefix = []) {
  const child = spawn(binary, [...prefix,'-c','features.plugins=false','-c','features.plugin_sharing=false',
    '-c','mcp_servers={}','app-server'],
    {cwd:plan.cwd,env:plan.environment,stdio:['pipe','pipe','pipe']});
  let buffer='', next=0, stderr=''; const pending=new Map();
  child.stderr.on('data', d=>{stderr+=d;});
  child.stdout.on('data', d=>{
    buffer+=d;
    while(buffer.includes('\n')) {
      const end=buffer.indexOf('\n'), reply=JSON.parse(buffer.slice(0,end)); buffer=buffer.slice(end+1);
      const waiter=pending.get(reply.id);
      if(waiter) {pending.delete(reply.id);reply.error?waiter.reject(new Error(JSON.stringify(reply.error))):waiter.resolve(reply.result);}
      else if(reply.id!=null && reply.method) {
        child.stdin.write(JSON.stringify({id:reply.id,error:{code:-32601,message:'fixture rejects unsolicited requests'}})+'\n');
      }
    }
  });
  child.on('exit',code=>{for(const waiter of pending.values()) waiter.reject(new Error(`Codex exit ${code}: ${stderr}`));pending.clear();});
  const timeout=setTimeout(()=>child.kill('SIGTERM'),30_000);
  return {
    request(method,params) {const id=++next;return new Promise((resolve,reject)=>{pending.set(id,{resolve,reject});child.stdin.write(JSON.stringify({id,method,params})+'\n');});},
    initialized() {child.stdin.write(JSON.stringify({method:'initialized'})+'\n');},
    async close() {clearTimeout(timeout);if(child.exitCode===null){const done=once(child,'exit');child.stdin.end();const stop=setTimeout(()=>child.kill('SIGTERM'),2000);await done;clearTimeout(stop);}}
  };
}
