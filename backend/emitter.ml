open Ast
open Printf
open Types
open Table
open Semant

let label = ref 0
let incLabel() = (label := !label+1; !label)

(* str を n 回コピーする *)
let rec nCopyStr n str =
    if n > 0 then str ^ (nCopyStr (pred n) str) else ""

(* 環境から変数情報を取得する関数 *)
let lookup id env =
  try env id with
  | No_such_symbol _ -> raise (Err ("unbound variable: " ^ id))

(* 呼出し時にcalleeに渡す静的リンク *)
let passLink src dst = 
  if src >= dst then 
    let deltaLevel = src-dst+1 in
      "\tmovq %rbp, %rax\n"
     ^ nCopyStr deltaLevel "\tmovq 16(%rax), %rax\n"
     ^ "\tpushq %rax\n"
  else
    "\tpushq %rbp\n"   

let output = ref ""

(* printfやscanfで使う文字列 *)
let io =  "IO:\n\t.string \"%lld\"\n"
            ^ "\t.text\n"
(* main関数の頭 *)
let header =  "\t.globl main\n"
            ^ "main:\n"
            ^ "\tpushq %rbp\n"        (* フレームポインタの保存 *)
            ^ "\tmovq %rsp, %rbp\n"   (* フレームポインタをスタックポインタの位置に *)
(* プロローグとエピローグ *)
let prologue = "\tpushq %rbp\n"       (* フレームポインタの保存 *)
             ^ "\tmovq %rsp, %rbp\n"  (* フレームポインタのスタックポインタ位置への移動 *)
let epilogue = "\tleaveq\n"            (* -> movq %ebp, %esp; popl %ebp *)
             ^ "\tretq\n"              (* 呼出し位置の次のアドレスへ戻る *)

(* 宣言部の処理：変数宣言->記号表への格納，関数定義->局所宣言の処理とコード生成 *)
let rec trans_dec ast nest tenv env = match ast with
   (* 関数定義の処理 *)
   FuncDec (s, l, _, block) -> 
       (* 仮引数の記号表への登録 *)
       let env' =  type_param_dec l (nest+1) tenv env in 
         (* 関数本体（ブロック）の処理 *)
         let code = trans_stmt block (nest+1) tenv env' in
             (* 関数コードの合成 *)
             output := !output ^
                 s ^ ":\n"               (* 関数ラベル *)
                 ^ prologue              (* プロローグ *)
                 ^ code                  (* 本体コード *)
                 ^ epilogue              (* エピローグ *)
   (* 変数宣言の処理 *)
 | VarDec (t,s) -> ()
   (* 型宣言の処理 *)
 | TypeDec (s,t) -> 
      let entry = tenv s in
         match entry with
             (NAME (_, ty_opt)) -> ty_opt := Some (create_ty t tenv)
           | _ -> raise (Err s)
(* 文の処理 *)
and trans_stmt ast nest tenv env = 
                 type_stmt ast env;
                 match ast with
                  (* 代入のコード：代入先フレームをsetVarで求める．*)
                     Assign (v, e) -> trans_exp e nest env
                                    ^ trans_var v nest env
                                    ^ "\tpopq (%rax)\n"
                  (* +=のコード *)
                   (* | Assign(v, e) -> 
                        trans_var v nest env
                        ^ "\tpopq %rax\n"
                        ^ "\tmovq (%rax), %rbx\n"
                        ^ trans_exp e nest env
                        ^ "\tpopq %rcx\n"
                        ^ "\taddq %rcx, %rbx\n"
                        ^ "\tmovq %rbx, (%rax)\n" *)
                  (* +=のコード *)
                   | Assign (Var v, CallFunc ("+", [VarExp (Var v'); e])) when v = v' -> 
                        trans_exp e nest env
                        ^ trans_var (Var v) nest env
                        ^ "\tpopq %rbx\n"
                        ^ "\tmovq (%rax), %rcx\n"
                        ^ "\taddq %rbx, %rcx\n"
                        ^ "\tmovq %rcx, (%rax)\n"
                   (* iprintのコード *)
                   | CallProc ("iprint", [arg]) -> 
                           (trans_exp arg nest env
                        ^  "\tpopq  %rsi\n"
                        ^  "\tleaq IO(%rip), %rdi\n"
                        ^  "\tmovq $0, %rax\n"
                        ^  "\tcallq printf\n")
                   (* sprintのコード *)
                   | CallProc ("sprint", [StrExp s]) -> 
                       (let l = incLabel() in
                              ("\t.data\n"
                            ^ sprintf "L%d:\t.string %s\n" l s
                            ^ "\t.text\n"
                            ^ sprintf "\tleaq L%d(%%rip), %%rdi\n" l 
                            ^  "\tmovq $0, %rax\n"     
                            ^ "\tcallq printf\n"))
                   (* scanのコード *)
                   | CallProc ("scan", [VarExp v]) ->
                               (trans_var v nest env
                             ^ "\tmovq %rax, %rsi\n"
                             ^ "\tleaq IO(%rip), %rdi\n"
                             ^ "\tmovq $0, %rax\n"
                             ^ "\tcallq scanf\n")
                  (* returnのコード *)
                  | CallProc ("return", [arg]) ->
                              trans_exp arg nest env
                            ^ "\tpopq %rax\n"
                  | CallProc ("new", [VarExp v]) ->
                        let size = calc_size (type_var v env) in
                      sprintf "\tmovq $%d, %%rdi\n" size
                            ^ "\tcallq malloc\n"
                            ^ "\tpushq %rax\n"
                            ^  trans_var v nest env
                            ^  "\tpopq (%rax)\n"
                  (* 手続き呼出しのコード *)
                  | CallProc (s, el) -> 
                      let entry = env s in 
                         (match entry with
                             (FunEntry {formals=_; result=_; level=level}) -> 
                                 (* 実引数のコード *)
                                 (* 16バイト境界に調整 *)
                                 (if (List.length el) mod 2 = 1 then "" else "\tpushq $0\n")
                               ^ List.fold_right  (fun  ast code -> code ^ (trans_exp ast nest env)) el "" 
                                 (* 静的リンクを渡すコード *)
                               ^  passLink nest level
                                 (* 関数の呼出しコード *)
                               ^  "\tcallq " ^ s ^ "\n"
                                 (* 積んだ引数+静的リンクを降ろす *)
                               ^  sprintf "\taddq $%d, %%rsp\n" ((List.length el + 1 + 1) / 2 * 2 * 8) 
                            | _ -> raise (No_such_symbol s)) 
                  (* ブロックのコード：文を表すブロックは，関数定義を無視する．*)
                  | Block (dl, sl) -> 
                       (* ブロック内宣言の処理 *)
                       let (tenv',env',addr') = type_decs dl nest tenv env in
                             List.iter (fun d -> trans_dec d nest tenv' env') dl;
                             (* フレームの拡張 *)
                             let ex_frame = sprintf "\tsubq $%d, %%rsp\n" ((-addr'+16)/16*16) in
                                  (* 本体（文列）のコード生成 *)
                                  let code = List.fold_left 
                                       (fun code ast -> (code ^ trans_stmt ast nest tenv' env')) "" sl
                                  (* 局所変数分のフレーム拡張の付加 *)
                                  in ex_frame ^ code
                  (* elseなしif文のコード *)
                  | If (e,s,None) -> let (condCode,l) = trans_cond e nest env in
                                                  condCode
                                                ^ trans_stmt s nest tenv env
                                                ^ sprintf "L%d:\n" l
                  (* elseありif文のコード *)
                  | If (e,s1,Some s2) -> let (condCode,l1) = trans_cond e nest env in
                                            let l2 = incLabel() in 
                                                  condCode
                                                ^ trans_stmt s1 nest tenv env
                                                ^ sprintf "\tjmp L%d\n" l2
                                                ^ sprintf "L%d:\n" l1
                                                ^ trans_stmt s2 nest tenv env 
                                                ^ sprintf "L%d:\n" l2
                  (* while文のコード *)
                  | While (e,s) -> let (condCode, l1) = trans_cond e nest env in
                                     let l2 = incLabel() in
                                         sprintf "L%d:\n" l2 
                                       ^ condCode
                                       ^ trans_stmt s nest tenv env
                                       ^ sprintf "\tjmp L%d\n" l2
                                       ^ sprintf "L%d:\n" l1
                  (* dowhile文のコード*)
                  | DoWhile (s, e) -> 
                    let l1 = incLabel() in
                    let (condCode, l2) = trans_cond e nest env in
                    sprintf "L%d:\n" l1
                    ^ trans_stmt s nest tenv env
                    ^ condCode
                    ^ sprintf "\tjmp L%d\n" l1
                    ^ sprintf "L%d:\n" l2
                  (* for文のコード *)
                  (* | For (var, start, end_expr, body) ->
                    let l1 = incLabel() in
                    let l2 = incLabel() in
                    trans_exp var start env  (* 変数の初期化 *)
                    ^ sprintf "L%d:\n" l1     (* ループのスタート地点にラベル *)
                    ^ trans_exp var end_expr  (* 終了条件の評価 *)
                    ^ sprintf "\tjge L%d\n" l2 (* 条件が満たされたらループ終了 *)
                    ^ trans_stmt body nest tenv env  (* ループ本体 *)
                    ^ sprintf "\tadd %s, 1\n" var  (* カウンタのインクリメント *)
                    ^ sprintf "\tjmp L%d\n" l1     (* 次の反復へジャンプ *)
                    ^ sprintf "L%d:\n" l2          ループ終了ラベル *)
                     (* for文のコード *)
                     | For (id, e1, e2, s) -> 
                      let gen_idx = trans_var (Var id) nest env in
                      let loopL = incLabel() in
                      let endL = incLabel() in
                      (* 初期化 *)
                      "# for loop\n"
                      ^
                      gen_idx
                      ^ trans_exp e1 nest env
                      ^ "\tpopq (%rax)\n"
                      ^ trans_exp e2 nest env
                      ^ "\tpopq %rbx\n"
                      ^ sprintf "L%d:\n" loopL
                      (* condition *)
                      ^ "# for loop condition\n"
                      ^ gen_idx
                      ^ "\tmovq (%rax), %rcx\n"
                      ^ "\tcmpq %rbx, %rcx\n"
                      ^ sprintf "\tjge L%d\n" endL
                      (* body *)
                      ^ "# for loop body\n"
                      ^ trans_stmt s nest tenv env
                      (* ループ変数をインクリメントする *)
                      ^ "# for loop increment\n"
                      ^ gen_idx
                      ^ "\tmovq (%rax), %rcx\n"
                      ^ "\tincq %rcx\n"
                      ^ "\tmovq %rcx, (%rax)\n"
                      ^ sprintf "\tjmp L%d\n" loopL
                      ^ sprintf "L%d:\n" endL
                  (* 空文 *)
                  | NilStmt -> ""
(* 参照アドレスの処理 *)
and trans_var ast nest env = match ast with
                   Var s -> let entry = env s in 
                        (match entry with
                            VarEntry {offset=offset; level=level; ty=_} -> 
                                  "\tmovq %rbp, %rax\n" 
                                ^ nCopyStr (nest-level) "\tmovq 16(%rax), %rax\n"
                                ^ sprintf "\tleaq %d(%%rax), %%rax\n" offset
                           | _ -> raise (No_such_symbol s))
                 | IndexedVar (v, size) -> 
                            trans_exp (CallFunc("*", [IntExp 8; size])) nest env
                          ^ trans_var v nest env
                          ^ "\tmovq (%rax), %rax\n"
                          ^ "\tpopq %rbx\n"
                          ^ "\tleaq (%rax,%rbx), %rax\n"
(* 式の処理 *)
and trans_exp ast nest env = match ast with
                  (* 整数定数のコード *)
                    IntExp i -> (sprintf "\tpushq $%d\n" i)
                  (* 変数参照のコード：reVarで参照フレームを求める *)
                  | VarExp v -> 
                             trans_var v nest env
                           ^ "\tmovq (%rax), %rax\n"
                           ^ "\tpushq %rax\n"
                  (* +のコード *)
                  | CallFunc ("+", [left; right]) -> 
                                             trans_exp left nest env
                                           ^ trans_exp right nest env
                                           ^ "\tpopq %rax\n"
                                           ^ "\taddq %rax, (%rsp)\n"
                  (* -のコード *)
                  | CallFunc ("-", [left; right]) ->
                                             trans_exp left nest env
                                           ^ trans_exp right nest env
                                           ^ "\tpopq %rax\n"
                                           ^ "\tsubq %rax, (%rsp)\n"
                  (* *のコード *)
                  | CallFunc ("*", [left; right]) ->
                                             trans_exp left nest env
                                           ^ trans_exp right nest env
                                           ^ "\tpopq %rax\n"
                                           ^ "\timulq (%rsp), %rax\n"
                                           ^ "\tmovq %rax, (%rsp)\n"
                  (* /のコード *)
                  | CallFunc ("/", [left; right]) ->
                                             trans_exp left nest env
                                           ^ trans_exp right nest env
                                           ^ "\tpopq %rbx\n"
                                           ^ "\tpopq %rax\n"
                                           ^ "\tcqto\n"
                                           ^ "\tidivq %rbx\n"
                                           ^ "\tpushq %rax\n"
    (* %のコード *)
    | CallFunc ("%", [left; right]) -> 
      trans_exp left nest env
      ^ trans_exp right nest env
      ^ "\tpopq %rbx\n"
      ^ "\tpopq %rax\n"
      ^ "\tcqto\n"
      ^ "\tidivq %rbx\n"
      ^ "\tpushq %rdx\n"
    (* ^のコード *)
    | CallFunc ("^", [left; right]) -> 
      let l = incLabel() in
      trans_exp left nest env
      ^ trans_exp right nest env
      ^ "\tpopq %rbx\n"
      ^ "\tpopq %rax\n"
      ^ "\tmovq $1, %rcx\n"
      ^ "\tcmpq $0, %rbx\n"
      ^ sprintf "\tjle L%d\n" l
      ^ sprintf "L%d:\n" l
      ^ "\timulq %rax, %rcx\n"
      ^ "\tdecq %rbx\n"
      ^ "\tcmpq $0, %rbx\n"
      ^ sprintf "\tjg L%d\n" l
      ^ "\tpushq %rcx\n"
    (* ++のコード *)
    | CallFunc ("++", [VarExp v]) -> 
      trans_var v nest env
      ^ "\tmovq (%rax), %rbx\n"
      ^ "\tpushq %rbx\n"
      ^ "\tincq %rbx\n"
      ^ "\tmovq %rbx, (%rax)\n"
                  (* 反転のコード *)
                  | CallFunc("!",  arg::_) -> 
                                             trans_exp arg nest env
                                           ^ "\tnegq (%rsp)\n"
                  (* 関数呼出しのコード *)
                  | CallFunc (s, el) -> 
                                 trans_stmt (CallProc(s, el)) nest initTable env 
                                 (* 返戻値は%raxに入れて返す *)
                               ^ "\tpushq %rax\n"
                  | _ -> raise (Err "internal error")
(* 関係演算の処理 *)
and trans_cond ast nest env = match ast with
                  | CallFunc (op, left::right::_) -> 
                      (let code = 
                       (* オペランドのコード *)
                          trans_exp left nest env
                        ^ trans_exp right nest env
                       (* オペランドの値を %rax，%rbxへ *)
                        ^ "\tpopq %rax\n"
                        ^ "\tpopq %rbx\n"
                       (* cmp命令 *)                       
                        ^ "\tcmpq %rax, %rbx\n" in
                          let l = incLabel () in
                             match op with
                               (* 条件と分岐の関係は，逆 *)
                                "==" -> (code ^ sprintf "\tjne L%d\n" l, l)
                              | "!=" -> (code ^ sprintf "\tje L%d\n"l, l)
                              | ">"  -> (code ^ sprintf "\tjle L%d\n" l, l)
                              | "<"  -> (code ^ sprintf "\tjge L%d\n" l, l)
                              | ">=" -> (code ^ sprintf "\tjl L%d\n" l, l)
                              | "<=" -> (code ^ sprintf "\tjg L%d\n" l, l)
                              | _ -> ("",0))
                 | _ -> raise (Err "internal error")
(* プログラム全体の生成 *)
let trans_prog ast = let code = trans_stmt ast 0 initTable initTable in
                                io ^ header ^ code ^ epilogue ^ (!output)
