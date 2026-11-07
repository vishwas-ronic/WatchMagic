The spec can have ONLY these three sections:

  What should it do?
  

  What does "done" look like?
 

  Where is the work?




What the last lines of the spec should be. verbatim:

None of the subagnets or you should ask me for yes no for anything, command etc. handle it before anything starts
make sure to git pull latest before you start

Give each part to its own subagent. When a subagent reports back, check its evidence before you accept it.
Keep a checklist in TASKS.md. Tick each item when it's done, and add anything new you find.
Stop and ask me only if when you are going out of scope. or changing the soul of the platform, or fixing instance vs process, or if you are creating a complex solution that can be done better if you just take a step back and analyse..
Before you report it finished, review your own diff and fix anything you'd block a merge for.
Mark anything you couldn't confirm, and say where you looked.

Testing should be done to make sure all changes are fine but testing shouldnt be so over done that time is wasted. ensure that testing is done, but not 1000 times. each change shouldnt require entire chain tested. maybe at larger instances like merging major works require testing! 

push all to main/master. 


End with three headings: Changed, Found, pending questions or blockers on me, if any, with your suggestions.  

deploy if nothing is pending on me. 


