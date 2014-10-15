
--Cracker64's Autorun Script Manager
--The autorun to end all autoruns
--VER 2.21 UPDATE http://pastebin.com/raw.php?i=FKxVYV01
 
--Version 2.21
 
--TODO:
--manual file addition (that can be anywhere and any extension)
--Moving window (because why not)
--some more API functions
--prettier, organize code
 
--CHANGES:
--Scan all subdirectories in scripts folder! v2.25
--Remove step hooks, v87 fixes them
--Socket is now default in v87+ , horray, everyone can now use update features without extra downloads.
--Handles up to 50 extra step functions, up from the default 5 (not including the manager's step) v2.1
--Other various nice API functions
--Scripts can store/retrieve settings through the manager, see comments below v2.0
--Small fillrect change for v85, boxes can have backgrounds v1.92
--Support spaces in exe names v1.91
--Auto-update for OTHER scripts now works, is a bit messy, will fix later, but nothing should change for users to use this
--  Place a line '--VER num UPDATE link' in one of the first four lines of the file, see my above example
--  The link at top downloads a file that contains ONLY version,full link,and prints the rest(changelog). See my link for example

if not socket then error("TPT version not supported") end

local VERSION = "2.21"
local TPT_LUA_PATH = 'scripts'
local PATH_SEP = '\\'
local WINDOWS=true
local EXE_NAME = "Powder.exe"
local CHECKUPDATE = false
if os.getenv('HOME') then
    PATH_SEP = '/'
    EXE_NAME = "powder"
    WINDOWS=false
end
local filenames = {}
local localscripts = {}
local onlinescripts = {}
local running = {}
local requiresrestart=false
local hidden_mode=true
local online = false
local updatecheckID = 'http://www.pastebin.com/raw.php?i=FKxVYV01'
local fullupdateID = nil
local gen_buttons
local sidebutton
local download_file
local settings = {}
math.randomseed(os.time()) math.random() math.random() math.random() --some filler randoms

--get line that can be saved into scriptinfo file
local function scriptInfoString(info)
    --Write table into data format
    if type(info)~="table" then return end
    local t = {}
    for k,v in pairs(info) do
        table.insert(t,k..":\""..v.."\"")
    end
    local rstr = table.concat(t,","):gsub("\n","\\n")
    return rstr
end

--read a scriptinfo line
local function readScriptInfo(list)
    local scriptlist = {}
    for i in list:gmatch("[^\n]+") do
        local t = {}
        local ID = 0
        for k,v in i:gmatch("(%w+):\"([^\"]*)\"") do
            t[k]= tonumber(v) or v:gsub("\\n","\n")
        end
        scriptlist[t.ID] = t
    end
    return scriptlist
end

--save settings
local function save_last()
    local savestring=""
    for script,v in pairs(running) do
        savestring = savestring.." \'"..script.."\'"
    end
    savestring = "SAV "..savestring.."\nEXE "..EXE_NAME.."\nDIR "..TPT_LUA_PATH
    for k,t in pairs(settings) do
	for n,v in pairs(t) do
	    savestring = savestring.."\nSET "..k.." "..n..":'"..v.."'"	    
	end
    end
    local f
    if TPT_LUA_PATH == "scripts" then
        f = io.open(TPT_LUA_PATH..PATH_SEP.."autorunsettings.txt", "w")
    else
        f = io.open("autorunsettings.txt", "w")
    end
    if f then
        f:write(savestring)
        f:close()
    end

    f = io.open(TPT_LUA_PATH..PATH_SEP.."downloaded"..PATH_SEP.."scriptinfo", "w")
    if f then
        for k,v in pairs(localscripts) do
            f:write(scriptInfoString(v).."\n")
        end
        f:close()
    end
end

--load settings before anything else
local function load_last()
    local f = io.open(TPT_LUA_PATH..PATH_SEP.."autorunsettings.txt","r")
    if not f then
        f = io.open("autorunsettings.txt","r")
    end
    if f then
        local lines = {}
        local line = f:read("*l")
        while line do
            table.insert(lines,line)
            line = f:read("*l")
        end
        f:close()
        for i=1, #lines do
            local tok=lines[i]:sub(1,3)
            local str=lines[i]:sub(5)
            if tok=="SAV" then
                for word in string.gmatch(str, "\'(.-)\'") do running[word] = true end
            elseif tok=="EXE" then
                EXE_NAME=str
            elseif tok=="DIR" then
                TPT_LUA_PATH=str
            elseif tok=="SET" then
	        local ident,name,val = string.match(str,"(.-) (.-):\'(.-)\'")
		if settings[ident] then settings[ident][name]=val
		else settings[ident]={[name]=val} end
            end
        end
    end

    f = io.open(TPT_LUA_PATH..PATH_SEP.."downloaded"..PATH_SEP.."scriptinfo","r")
    if f then
        local lines = f:read("*a")
        f:close()
        localscripts = readScriptInfo(lines)
    end
end
load_last()
--get list of files in scripts folder
local function load_filenames()
    filenames = {}
    local function searchRecursive(directory)
        local dirlist = fs.list(directory)
        if not dirlist then return end
        for i,v in ipairs(dirlist) do
            local file = directory.."/"..v
            if fs.isDirectory(file) then
                searchRecursive(file)
            elseif fs.isFile(file) then
                if file:find("%.lua$") then
                    local toinsert = file:sub(#TPT_LUA_PATH+2)
                    if WINDOWS then
                        toinsert = toinsert:gsub("/", "\\") --not actually required
                    end
                    table.insert(filenames, toinsert)
                end
            end
        end
    end
    searchRecursive(TPT_LUA_PATH)
end
--ui object stuff
local ui_base local ui_box local ui_line local ui_text local ui_button local ui_scrollbar local ui_tooltip local ui_checkbox local ui_console local ui_window
local tooltip
ui_base = {
new = function()
    local b={}
    b.drawlist = {}
    function b:drawadd(f)
        table.insert(self.drawlist,f)
    end
    function b:draw(...)
        for _,f in ipairs(self.drawlist) do
            if type(f)=="function" then
                f(self,unpack(arg))
            end
        end
    end
    b.movelist = {}
    function b:moveadd(f)
        table.insert(self.movelist,f)
    end
    function b:onmove(x,y)
        for _,f in ipairs(self.movelist) do
            if type(f)=="function" then
                f(self,x,y)
            end
        end
    end
    return b
end
}
ui_box = {
new = function(x,y,w,h,r,g,b)
    local box=ui_base.new()
    box.x=x box.y=y box.w=w box.h=h box.x2=x+w box.y2=y+h
    box.r=r or 255 box.g=g or 255 box.b=b or 255
    function box:setcolor(r,g,b) self.r=r self.g=g self.b=b end
    function box:setbackground(r,g,b,a) self.br=r self.bg=g self.bb=b self.ba=a end
    box.drawbox=true
    box.drawbackground=false
    box:drawadd(function(self) if self.drawbackground then tpt.fillrect(self.x,self.y,self.w+1,self.h+1,self.br,self.bg,self.bb,self.ba) end
                                if self.drawbox then tpt.drawrect(self.x,self.y,self.w,self.h,self.r,self.g,self.b) end end)
    box:moveadd(function(self,x,y)
        if x then self.x=self.x+x self.x2=self.x2+x end
        if y then self.y=self.y+y self.y2=self.y2+y end
    end)
    return box
end
}
ui_line = {
new=function(x,y,x2,y2,r,g,b)
    local line=ui_box.new(x,y,x2-x,y2-y,r,g,b)
    --Line is essentially a box, but with a different draw
    line.drawlist={}
    line:drawadd(function(self) tpt.drawline(self.x,self.y,self.x2,self.y2,self.r,self.g,self.b) end)
    return line
    end
}
ui_text = {
new = function(text,x,y,r,g,b)
    local txt = ui_base.new()
    txt.text = text
    txt.x=x or 0 txt.y=y or 0 txt.r=r or 255 txt.g=g or 255 txt.b=b or 255
    function txt:setcolor(r,g,b) self.r=r self.g=g self.b=b end
    txt:drawadd(function(self,x,y) tpt.drawtext(x or self.x,y or self.y,self.text,self.r,self.g,self.b) end)
    txt:moveadd(function(self,x,y)
        if x then self.x=self.x+x end
        if y then self.y=self.y+y end  
    end)
    function txt:process() return false end
    return txt
end,
--Scrolls while holding mouse over
newscroll = function(text,x,y,vis,r,g,b)
    local txt = ui_text.new(text,x,y,r,g,b)
    if tpt.textwidth(text)<vis then return txt end
    txt.visible=vis
    txt.length=string.len(text)
    txt.start=1
    txt.drawlist={} --reset draw
    txt.timer=socket.gettime()+3
    function txt:cuttext(self)
        local last = self.start+1
        while tpt.textwidth(self.text:sub(self.start,last))<txt.visible and last<=self.length do
            last = last+1
        end
        self.last=last-1
    end
    txt:cuttext(txt)
    txt.minlast=txt.last-1
    txt.ppl=((txt.visible-6)/(txt.length-txt.minlast+1))
    txt:drawadd(function(self,x,y)
        if socket.gettime() > self.timer then
            if self.last >= self.length then
                self.start = 1
                self:cuttext(self)
                self.timer = socket.gettime()+3
            else
                self.start = self.start + 1
                self:cuttext(self)
                if self.last >= self.length then
                    self.timer = socket.gettime()+3
                else
                    self.timer = socket.gettime()+.15
                end
            end
        end
        tpt.drawtext(x or self.x,y or self.y, self.text:sub(self.start,self.last) ,self.r,self.g,self.b)
    end)
    function txt:process(mx,my,button,event,wheel)
        if event==3 then
            local newlast = math.floor((mx-self.x)/self.ppl)+self.minlast
            if newlast<self.minlast then newlast=self.minlast end
            if newlast>0 and newlast~=self.last then
                local newstart=1
                while tpt.textwidth(self.text:sub(newstart,newlast))>= self.visible do
                    newstart=newstart+1
                end
                self.start=newstart self.last=newlast
                self.timer = socket.gettime()+3
            end
        end
    end
    return txt
end
}
ui_scrollbar = {
new = function(x,y,h,t,m)
    local bar = ui_base.new() --use line object as base?
    bar.x=x bar.y=y bar.h=h
    bar.total=t
    bar.numshown=m
    bar.pos=0
    bar.length=math.floor((1/math.ceil(bar.total-bar.numshown+1))*bar.h)
    bar.soffset=math.floor(bar.pos*((bar.h-bar.length)/(bar.total-bar.numshown)))
    function bar:update(total,shown,pos)
        self.pos=pos or 0
        if self.pos<0 then self.pos=0 end
        self.total=total
        self.numshown=shown
        self.length= math.floor((1/math.ceil(self.total-self.numshown+1))*self.h)
        self.soffset= math.floor(self.pos*((self.h-self.length)/(self.total-self.numshown)))
    end
    function bar:move(wheel)
        self.pos = self.pos-wheel
        if self.pos < 0 then self.pos=0 end
        if self.pos > (self.total-self.numshown) then self.pos=(self.total-self.numshown) end
        self.soffset= math.floor(self.pos*((self.h-self.length)/(self.total-self.numshown)))
    end
    bar:drawadd(function(self)
        if self.total > self.numshown then
            tpt.drawline(self.x,self.y+self.soffset,self.x,self.y+self.soffset+self.length)
        end
    end)
    bar:moveadd(function(self,x,y)
        if x then self.x=self.x+x end
        if y then self.y=self.y+y end  
    end)
    function bar:process(mx,my,button,event,wheel)
        if wheel~=0 and not hidden_mode then
            if self.total > self.numshown then
                local previous = self.pos
                self:move(wheel)
                if self.pos~=previous then
                    return wheel
                end
            end
        end
        --possibly click the bar and drag?
        return false
    end
    return bar
end
}
ui_button = {
new = function(x,y,w,h,f,text)
    local b = ui_box.new(x,y,w,h)
    b.f=f
    b.t=ui_text.new(text,x+2,y+2)
    b.drawbox=false
    b.almostselected=false
    b.invert=true
    b:setbackground(127,127,127,125)
    b:drawadd(function(self)
        if self.invert and self.almostselected then
            self.almostselected=false
            tpt.fillrect(self.x,self.y,self.w,self.h)
            local tr=self.t.r local tg=self.t.g local tb=self.t.b
            b.t:setcolor(0,0,0)
            b.t:draw()
            b.t:setcolor(tr,tg,tb)
        else
            if tpt.mousex>=self.x and tpt.mousex<=self.x2 and tpt.mousey>=self.y and tpt.mousey<=self.y2 then
                self.drawbackground=true
            else
                self.drawbackground=false
            end
            b.t:draw()
        end
    end)
    b:moveadd(function(self,x,y)
        self.t:onmove(x,y)
    end)
    function b:process(mx,my,button,event,wheel)
        if mx<self.x or mx>self.x2 or my<self.y or my>self.y2 then return false end
        if event==3 then self.almostselected=true end
        if event==2 then self:f() end
        return true
    end
    return b
end
}
ui_tooltip = {
new = function(x,y,w,text)
    local b = ui_box.new(x,y-1,w,0)
    function b:updatetooltip(tooltip)
        self.tooltip = tooltip
        self.length = #tooltip
        self.lines = 0
        local start,last = 1,2
        while last <= self.length do
            while tpt.textwidth(self.tooltip:sub(start,last)) < w and last <= self.length and self.tooltip:sub(last,last) ~= '\n' do
                last = last + 1
            end
            if last <= self.length and self.tooltip:sub(last,last) ~= '\n' then
                self.length = self.length + 1
                self.tooltip = self.tooltip:sub(1,last-1).."\n"..self.tooltip:sub(last)
            end
            last = last + 1
            start = last
            self.lines = self.lines + 1
	    end
        self.h = self.lines*12+2
        --if self.lines == 1 then self.w = tpt.textwidth(self.tooltip)+3 end
        self.drawbox = tooltip ~= ""
        self.drawbackground = tooltip ~= ""
    end
    b:updatetooltip(text)
    b:setbackground(0,0,0,255)
	b.drawbackground = true
    b:drawadd(function(self)
        if self.tooltip ~= "" then
            tpt.drawtext(self.x+1,self.y+2,self.tooltip)
        end
        self:updatetooltip("")
    end)
    function b:process(mx,my,button,event,wheel) end
    return b
end
}
ui_checkbox = {
up_button = function(x,y,w,h,f,text,filename)
    local b=ui_button.new(x,y,w,h,f,text)
    b.updateLink=""
    b.checkLink=""
    b.curversion=""
    b.canupdate=false --if file has UPDATE link
    b.hasupdate=false --if link gives newer version
    b.filename=filename
    b:drawadd(function(self)
        if self.canupdate then tpt.drawtext(self.x-22,self.y+2,self.curversion) end
    end)
    return b
end,
new_button = function(x,y,w,h,splitx,f,f2,text)
    local b = ui_box.new(x,y,splitx,h)
    b.f=f b.f2=f2
    b.splitx = splitx
    b.t=ui_text.newscroll(text,x+24,y+2,splitx-24)
    b.selected=false
    b.checkbut=ui_checkbox.up_button(x+splitx+33,y,33,10,ui_button.scriptcheck,"Check",text)
    b.drawbox=false
    b:setbackground(127,127,127,100)
    b:drawadd(function(self)
        if tpt.mousex>=self.x and tpt.mousex<self.x2 and tpt.mousey>=self.y and tpt.mousey<self.y2 then
            if online and onlinescripts[self.ID]["description"] then
                tooltip:onmove(tpt.mousex-tooltip.x, tpt.mousey-tooltip.y)
                tooltip:updatetooltip(onlinescripts[self.ID]["description"])
            end
            self.drawbackground=true
        else
            self.drawbackground=false
        end
        self.t:draw()
        if self.f2 then
            if self.deletealmostselected then
                self.deletealmostselected = false
                tpt.drawtext(self.x+1, self.y+1, "\134", 255, 48, 32, 255)
            else
                tpt.drawtext(self.x+1, self.y+1, "\134", 160, 48, 32, 255)
            end
            tpt.drawtext(self.x+1, self.y+1, "\133", 255, 255, 255, 255)
        end
        tpt.drawrect(self.x+12,self.y+1,8,8)
        if self.almostselected then self.almostselected=false tpt.fillrect(self.x+12,self.y+1,8,8,150,150,150)
        elseif self.selected then tpt.fillrect(self.x+12,self.y+1,8,8) end
        if running[self.t.text] then tpt.drawtext(self.x+self.splitx+2,self.y+2,"R") end
        if self.checkbut.canupdate then self.checkbut:draw() end
    end)
    b:moveadd(function(self,x,y)
        self.t:onmove(x,y)
        self.checkbut:onmove(x,y)
    end)
    function b:process(mx,my,button,event,wheel)
        if self.f2 and mx <= self.x+8 then
            if event==3 then self.deletealmostselected = true end
            if event==2 then self:f2() end
        elseif mx<=self.x+self.splitx then
            if event==3 then self.almostselected=true end
            if event==2 then self:f() end
            self.t:process(mx,my,button,event,wheel)
        else
            if self.checkbut.canupdate then self.checkbut:process(mx,my,button,event,wheel) end
        end
        return true
    end
    return b
end,
new = function(x,y,w,h)
    local box = ui_box.new(x,y,w,h)
    box.list={}
    box.numlist = 0
    box.max_lines = math.floor(box.h/10)-1
    box.max_text_width = math.floor(box.w*0.7)
    box.splitx=x+box.max_text_width
    box.scrollbar = ui_scrollbar.new(box.x2-2,box.y+11,box.h-12,0,box.max_lines)
    box.lines={
        ui_line.new(box.x+1,box.y+10,box.x2-1,box.y+10,170,170,170),
        ui_line.new(box.x+22,box.y+10,box.x+22,box.y2-1,170,170,170),
        ui_line.new(box.splitx,box.y+10,box.splitx,box.y2-1,170,170,170),
        ui_line.new(box.splitx+9,box.y+10,box.splitx+9,box.y2-1,170,170,170),
        ui_line.new(box.splitx+33,box.y+10,box.splitx+33,box.y2-1,170,170,170),
    }
    function box:updatescroll()
        self.scrollbar:update(self.numlist,self.max_lines)
    end
    function box:clear()
        self.list={}
        self.numlist=0
    end
    function box:add(f,f2,text)
        local but = ui_checkbox.new_button(self.x,self.y+1+((self.numlist+1)*10),tpt.textwidth(text)+4,10,self.max_text_width,f,f2,text)
        table.insert(self.list,but)
        self.numlist = #self.list
        return but
    end
    box:drawadd(function (self)
        tpt.drawtext(self.x+24,self.y+2,"Files in "..TPT_LUA_PATH.." folder")
        tpt.drawtext(self.splitx+11,self.y+2,"Ver  Update")
        for i,line in ipairs(self.lines) do
            line:draw()
        end
        self.scrollbar:draw()
        local restart = false
        for i,check in ipairs(self.list) do
            if not check.selected and running[check.t.text] then
                restart=true
            end
            if i>self.scrollbar.pos and i<=self.scrollbar.pos+self.max_lines then
                check:draw()
            end
        end
        requiresrestart=restart
    end)
    box:moveadd(function(self,x,y)
        for i,line in ipairs(self.lines) do
            line:onmove(x,y)
        end
        for i,check in ipairs(self.list) do
            check:onmove(x,y)
        end
    end)
    function box:scroll(amount)
        local move = amount*10
        if move==0 then return end
        for i,check in ipairs(self.list) do
            check:onmove(0,move)
        end
    end
    function box:process(mx,my,button,event,wheel)
        if mx<self.x or mx>self.x2 or my<self.y or my>self.y2 then return false end
        local scrolled = self.scrollbar:process(mx,my,button,event,wheel)
        if scrolled then self:scroll(scrolled) end
        local which = math.floor((my-self.y-11)/10)+1
        if which>0 and which<=self.numlist then self.list[which+self.scrollbar.pos]:process(mx,my,button,event,wheel) end
        return true
    end
    return box
end
}
ui_console = {
new = function(x,y,w,h)
    local con = ui_box.new(x,y,w,h)
    con.shown_lines = math.floor(con.h/10)
    con.max_lines = 300
    con.max_width = con.w-4
    con.lines = {}
    con.scrollbar = ui_scrollbar.new(con.x2-2,con.y+1,con.h-2,0,con.shown_lines)
    con:drawadd(function(self)
        self.scrollbar:draw()
        local count=0
        for i,line in ipairs(self.lines) do
            if i>self.scrollbar.pos and i<= self.scrollbar.pos+self.shown_lines then
                line:draw(self.x+3,self.y+3+(count*10))
                count = count+1
            end
        end
    end)
    con:moveadd(function(self,x,y)
        self.scrollbar:onmove(x,y)
    end)
    function con:clear()
        self.lines = {}
        self.scrollbar:update(0,con.shown_lines)
    end
    function con:addstr(str,r,g,b)
        str = tostring(str)
        local nextl = str:find('\n')
        while nextl do
            local line = str:sub(1,nextl-1)
            self:addline(line,r,g,b)
            str = str:sub(nextl+1)
            nextl = str:find('\n')
        end
        self:addline(str,r,g,b) --anything leftover
    end
    function con:addline(line,r,g,b)
        if not line or line=="" then return end --No blank lines
        table.insert(self.lines,ui_text.newscroll(line,self.x,0,self.max_width,r,g,b))
        if #self.lines>self.max_lines then table.remove(self.lines,1) end
        self.scrollbar:update(#self.lines,self.shown_lines,#self.lines-self.shown_lines)
    end
    function con:process(mx,my,button,event,wheel)
        if mx<self.x or mx>self.x2 or my<self.y or my>self.y2 then return false end
        self.scrollbar:process(mx,my,button,event,wheel)
        local which = math.floor((my-self.y-1)/10)+1
        if which>0 and which<=self.shown_lines and self.lines[which+self.scrollbar.pos] then self.lines[which+self.scrollbar.pos]:process(mx,my,button,event,wheel) end
        return true
    end
    return con
end
}
ui_window = {
new = function(x,y,w,h)
    local w=ui_box.new(x,y,w,h)
    w.sub={}
    function w:add(m,name)
        if name then w[name]=m end
        table.insert(self.sub,m)
    end
    w:drawadd(function(self)
        for i,sub in ipairs(self.sub) do
            sub:draw()
        end
    end)
    w:moveadd(function(self,x,y)
        for i,sub in ipairs(self.sub) do
            sub:onmove(x,y)
        end
    end)
    function w:process(mx,my,button,event,wheel)
        if mx<self.x or mx>self.x2 or my<self.y or my>self.y2 then return false end
        local ret
        for i,sub in ipairs(self.sub) do
            if sub:process(mx,my,button,event,wheel) then ret = true end
        end
        return ret
    end
    return w
end
}
--Main window with everything!
local mainwindow = ui_window.new(50,50,525,300)
mainwindow:setbackground(10,10,10,235) mainwindow.drawbackground=true
mainwindow:add(ui_console.new(275,148,300,189),"menuconsole")
mainwindow:add(ui_checkbox.new(50,80,225,257),"checkbox")
tooltip = ui_tooltip.new(0,1,150,"")

--Some API functions you can call from other scripts
--put 'using_manager=MANAGER_EXISTS' or similar in your scripts, using_manager will be true if the manager is active
MANAGER_EXISTS = true
--Print a message to the manager console, can be colored
function MANAGER_PRINT(msg,...)
    mainwindow.menuconsole:addstr(msg,unpack(arg))
end
--send version, for some compatibility
function MANAGER_VERSION()
    return VERSION
end
--downloads and returns a file, so you can do whatever...
function MANAGER_DOWNLOAD(url)
    return download_file(url)
end
--Get various info about the system (if on windows, script directory, path seperator, if socket is loaded)
function MANAGER_SYSINFO()
    return {["isWindows"]=WINDOWS,["scriptDir"]=TPT_LUA_PATH,["pathSep"]=PATH_SEP,["socket"]=true}
end
--Get whether or not the manager window is hidden or not
function MANAGER_HIDDEN()
    return hidden_mode
end
--Save a setting in the autorun settings file, ident should be your script name no one else would use. 
--Name is variable name, val is the value which will be saved/returned as a string
function MANAGER_SAVESETTING(ident,name,val)
    ident = tostring(ident)
    name = tostring(name)
    val = tostring(val)
    if settings[ident] then settings[ident][name]=val
    else settings[ident]={[name]=val} end
    save_last()
end
--Get a previously saved value, if it has one
function MANAGER_GETSETTING(ident,name)
    if settings[ident] then return settings[ident][name] end
    return nil
end
--delete a setting, leave name nil to delete all of ident
function MANAGER_DELSETTING(ident,name)
    if settings[ident] then 
	if name then settings[ident][name]=nil
	else settings[ident]=nil end
	save_last()
    end
end
--some other API functions here..
 
--mniip's download thing (mostly)
local pattern = "http://w*%.?(.-)(/.*)"
local function download_file(url)
    local _,_,host,rest = url:find(pattern)
    if not host or not rest then MANAGER_PRINT("Bad link") return end
    local conn=socket.tcp()
    if not conn then return end
    local succ=pcall(conn.connect,conn,host,80)
    conn:settimeout(5)
    if not succ then return end
    succ,resp,something=pcall(conn.send,conn,"GET "..rest.." HTTP/1.1\r\nHost: "..host.."\r\nConnection: close\r\n\n")
    if not succ then return end
    local data=""
    local c=""
    while c do
        c=conn:receive("*l")
        if c then
            data=data.."\n"..c
        end
    end
    if data=="" then MANAGER_PRINT("no data") return end
    local first,last,code = data:find("HTTP/1%.1 (.-) .-\n")
    while last do
        data = data:sub(last+1)
        first,last,header = data:find("^([^\n]-:.-)\n")
        --read something from headers?
        if header then
            if tonumber(code)==302 then
                local _,_,new = header:find("^Location: (.*)")
                if new then return download_file(new) end
            end
        end
    end
    if host:find("pastebin.com") then --pastebin adds some weird numbers
        _,_,data=data:find("\n[^\n]*\n(.*)\n.+\n$")
    end
    return data
end
--Downloads to a location
local function download_script(url,location)
    local file = download_file(url)
    if file then
        f=io.open(location,"w")
        f:write(file)
        f:close()
        return true
    end
    return false
end
local function check_update(id)
    local file = download_file(id)
    if file then
        local _,_,version,updateLink,changelog = file:find('^\n?(.-)\n(.-)\n(.-)\n?$')
        return version,updateLink,changelog
    end
end
--Restart exe (if named correctly)
local function do_restart()
    save_last()
    if WINDOWS then
        os.execute("TASKKILL /IM \""..EXE_NAME.."\" /F &&START .\\\""..EXE_NAME.."\"")
    else
        os.execute("killall -s KILL \""..EXE_NAME.."\" && ./\""..EXE_NAME.."\"")
    end
    MANAGER_PRINT("Restart failed, do you have the exe name right?",255,0,0)
end
--TPT interface
local function step()
    tpt.fillrect(-1,-1,gfx.WIDTH,gfx.HEIGHT,0,0,0,150)
    mainwindow:draw()
    tpt.drawtext(280,140,"Console Output:")
    if requiresrestart then
        tpt.drawtext(280,88,"Disabling a script requires a restart for effect!",255,50,50)
    end
    tpt.drawtext(55,55,"Click a script to toggle, hit DONE when finished")
    tpt.drawtext(474,55,"Script Manager v"..VERSION)--479 for simple versions
    tooltip:draw()
end
local function mouseclick(mousex,mousey,button,event,wheel)
    sidebutton:process(mousex,mousey,button,event,wheel)
    if hidden_mode then return true end
   
    if mousex>612 or mousey>384 then return false end
    mainwindow:process(mousex,mousey,button,event,wheel)
    return false
end
local function keypress(key,nkey,modifier,event)
    if nkey==27 then hidden_mode=true return false end
    if not hidden_mode then return false end
end
--small button on right to bring up main menu
local WHITE = {255,255,255,255}
local BLACK = {0,0,0,255}
local sidecoords = {612,134,16,17}
local ICON = math.random(2) --pick a random icon
local lua_letters= {{{615,136,615,141},{615,141,617,141},{619,141,619,145},{619,145,621,145},{621,141,621,145},{623,145,625,145},{623,145,623,149},{624,147,624,147},{625,145,625,149},},
    {{615,137,615,147},{615,148,620,148},{617,137,617,146},{617,146,620,146},{620,137,620,146},{622,137,625,137},{622,137,622,148},{623,142,624,142},{625,137,625,148},}}
local function smallstep()
    tpt.drawrect(613,135,14,15,200,200,200)
    local color=WHITE
    if not hidden_mode then 
		step()
		tpt.fillrect(unpack(sidecoords))
		color=BLACK
	end
    for i,dline in ipairs(lua_letters[ICON]) do
        tpt.drawline(dline[1],dline[2],dline[3],dline[4],color[1],color[2],color[3])
    end
end
--button functions on click
function ui_button.reloadpressed(self)
    load_filenames()
    gen_buttons()
    mainwindow.checkbox:updatescroll()
    if #filenames == 0 then
        MANAGER_PRINT("No scripts found in '"..TPT_LUA_PATH.."' folder",255,255,0)
        fs.makeDirectory(TPT_LUA_PATH)
    else
        MANAGER_PRINT("Reloaded file list, found "..#filenames.." scripts")
    end
end
function ui_button.selectnone(self)
    for i,but in ipairs(mainwindow.checkbox.list) do
        but.selected = false
    end
end
function ui_button.consoleclear(self)
    mainwindow.menuconsole:clear()
end
function ui_button.changeexename(self)
    local last = EXE_NAME
    local new = tpt.input("Change exe name","Enter the exact name of powder toy executable",EXE_NAME,EXE_NAME)
    if new~=last and new~="" then
        MANAGER_PRINT("Executable name changed to "..new,255,255,0)
        EXE_NAME = new
    end
    save_last()
end
function ui_button.changedir(self)
    local last = TPT_LUA_PATH
    local new = tpt.input("Change search directory","Enter the folder where your scripts are",TPT_LUA_PATH,TPT_LUA_PATH)
    if new~=last and new~="" then
        MANAGER_PRINT("Directory changed to "..new,255,255,0)
        TPT_LUA_PATH = new
    end
    ui_button.reloadpressed()
    save_last()
end
local lastpaused
function ui_button.sidepressed(self)
    hidden_mode = not hidden_mode
    ui_button.localview()
    if not hidden_mode then
        lastpaused = tpt.set_pause()
        tpt.set_pause(1)
        ui_button.reloadpressed()
    else
        tpt.set_pause(lastpaused)
    end
end
local donebutton
function ui_button.donepressed(self)
    hidden_mode = true
    running = {}
    for i,but in ipairs(mainwindow.checkbox.list) do
        if but.selected then
            if requiresrestart then
                running[but.t.text] = true
            elseif not running[but.t.text] then
                local status,err = pcall(dofile,TPT_LUA_PATH..PATH_SEP..but.t.text)
                if not status then
                    MANAGER_PRINT(err,255,0,0)
                    print(err)
                    but.selected = false
                else
                    MANAGER_PRINT("Started "..but.t.text)
                    running[but.t.text] = true
                end
            end
        end
    end
    if requiresrestart then do_restart() return end
    save_last()
end
function ui_button.downloadpressed(self)
    for i,but in ipairs(mainwindow.checkbox.list) do
        if but.selected then
            --maybe do better display names later
            local displayName
            local function get_script(butt)
                local script = download_file("http://starcatcher.us/scripts/main.lua?get="..butt.ID)
                displayName = "downloaded"..PATH_SEP..butt.ID.." "..onlinescripts[butt.ID].author.."-"..onlinescripts[butt.ID].name..".lua"
                local name = TPT_LUA_PATH..PATH_SEP..displayName
                if not fs.exists(TPT_LUA_PATH..PATH_SEP.."downloaded") then
                    fs.makeDirectory(TPT_LUA_PATH..PATH_SEP.."downloaded")
                end
                local file = io.open(name, "w")
                if not file then error("could not open "..name) end
                file:write(script)
                file:close()
                localscripts[butt.ID] = onlinescripts[butt.ID]
                dofile(name)
            end
            local status,err = pcall(get_script, but)
            if not status then
                MANAGER_PRINT(err,255,0,0)
                print(err)
                but.selected = false
            else
                MANAGER_PRINT("Downloaded and started "..but.t.text)
                running[displayName] = true
            end
        end
    end
    hidden_mode=true
    ui_button.localview()
    save_last()
end
 
function ui_button.pressed(self)
    self.selected = not self.selected
end
function ui_button.delete(self)
    --there is no tpt.confirm() yet
    if tpt.input("Delete File", "Delete "..self.t.text.."?", "yes", "no") == "yes" then
        fs.removeFile(TPT_LUA_PATH.."/"..self.t.text:gsub("\\","/"))
        if running[self.t.text] then running[self.t.text] = nil end
        if localscripts[self.t.text] then localscripts[self.t.text] = nil end
        save_last()
        ui_button.localview()
        load_filenames()
        gen_buttons()
    end
end
function ui_button.scriptcheck(self)
    if self.canupdate and not self.hasupdate then
        local version,updateLink,changelog=check_update(self.checkLink)
        if tonumber(version)>tonumber(self.curversion) then
            MANAGER_PRINT("An update for "..self.filename.." is available! (v "..version..") Click Update",25,255,55)
            MANAGER_PRINT(changelog,25,255,55)
            self.updateLink=updateLink self.t.text="Update" self.hasupdate=true
        else MANAGER_PRINT("v"..self.curversion.." is latest version") end
    elseif self.hasupdate then
        if download_script(self.updateLink,TPT_LUA_PATH..PATH_SEP..self.filename) then
            MANAGER_PRINT("Downloaded update! Restart if it is running")
            self.canupdate=false
        end
    end
end
function ui_button.checkupdate(self)
    if not self.canupdate then
        local version,updateLink,changelog=check_update(updatecheckID)
        if tonumber(version)>tonumber(VERSION) then
            MANAGER_PRINT("A script manager update is available! (v "..version..") Click UPDATE",25,255,55)
            MANAGER_PRINT(changelog,25,255,55)
            fullupdateID=updateLink
            self.canupdate=true
            self.t.text="UPDATE" self.w=40 self.x2=self.x2-36 self.t:setcolor(25,255,25)
        else MANAGER_PRINT("v"..VERSION.." is latest version") end
    else
        fileSystem.move("autorun.lua", "autorunold.lua")
        download_script(fullupdateID,'autorun.lua')
        do_restart()
    end
end
function ui_button.localview(self)
    if online then
        online = false
        gen_buttons()
        donebutton.t.text = "DONE"
        donebutton.w = 29 donebutton.x2 = donebutton.x + donebutton.w
        donebutton.f = ui_button.donepressed
    end
end
function ui_button.onlineview(self)
    if not online then
        online = true
        gen_buttons()
        donebutton.t.text = "DOWNLOAD"
        donebutton.w = 55 donebutton.x2 = donebutton.x + donebutton.w
        donebutton.f = ui_button.downloadpressed
    end
end
--add buttons to window
donebutton = ui_button.new(55,339,29,10,ui_button.donepressed,"DONE")
mainwindow:add(donebutton)
mainwindow:add(ui_button.new(134,339,40,10,ui_button.sidepressed,"CANCEL"))
--mainwindow:add(ui_button.new(152,339,29,10,ui_button.selectnone,"NONE"))
local nonebutton = ui_button.new(62,81,8,8,ui_button.selectnone,"")
nonebutton.drawbox = true
mainwindow:add(nonebutton)
mainwindow:add(ui_button.new(538,339,33,10,ui_button.consoleclear,"CLEAR"))
mainwindow:add(ui_button.new(278,67,40,10,ui_button.reloadpressed,"RELOAD"))
mainwindow:add(ui_button.new(338,67,80,10,ui_button.changeexename,"Change exe name"))
mainwindow:add(ui_button.new(438,67,52,10,ui_button.changedir,"Change dir"))
mainwindow:add(ui_button.new(278,127,76,10,ui_button.checkupdate,"CHECK UPDATE"))
local tempbutton = ui_button.new(60, 65, 30, 10, ui_button.localview, "Local")
tempbutton.drawbox = true
mainwindow:add(tempbutton)
tempbutton = ui_button.new(100, 65, 35, 10, ui_button.onlineview, "Online")
tempbutton.drawbox = true
mainwindow:add(tempbutton)
sidebutton = ui_button.new(613,134,14,15,ui_button.sidepressed,'')

local function gen_buttons_local()
    --remember if a script was running before reload
    for i=1,#filenames do
        mainwindow.checkbox:add(ui_button.pressed,ui_button.delete,filenames[i])
        if running[filenames[i]] then mainwindow.checkbox.list[i].running=true mainwindow.checkbox.list[i].selected=true end
        local f = io.open(TPT_LUA_PATH..PATH_SEP..filenames[i])
        if f then
            local line = f:read("*l")
            local count=0 --check first 5 lines of files for update
            while line and count<5 do
                count=count+1
                local _,_,ver,link = line:find("^--VER (.*) UPDATE (.*)$")
                if ver and link then mainwindow.checkbox.list[i].checkbut.canupdate=true mainwindow.checkbox.list[i].checkbut.curversion=ver mainwindow.checkbox.list[i].checkbut.checkLink=link end
                line = f:read("*l")
            end
            f:close()
        end
    end
end
local function gen_buttons_online()
    local list = download_file("http://starcatcher.us/scripts/main.lua")
    onlinescripts = readScriptInfo(list)
    local count = 1
    for k,v in pairs(onlinescripts) do
        mainwindow.checkbox:add(ui_button.pressed, nil, v["name"])
        mainwindow.checkbox.list[count].ID = k
        mainwindow.checkbox.list[count].checkbut.curversion = v["version"] or "1.00"
        mainwindow.checkbox.list[count].checkbut.canupdate = true
        count = count + 1
    end
end
gen_buttons = function()
    mainwindow.checkbox:clear()
    if online then
        gen_buttons_online()
    else
        gen_buttons_local()
    end
    mainwindow.checkbox:updatescroll()
end
gen_buttons()

--register manager first
tpt.register_step(smallstep)
--load previously running scripts
local started = ""
for prev,v in pairs(running) do
    local status,err = pcall(dofile,TPT_LUA_PATH..PATH_SEP..prev)
    if not status then
        MANAGER_PRINT(err,255,0,0)
        running[prev] = nil
    else
        started=started.." "..prev
        local newbut = mainwindow.checkbox:add(ui_button.pressed,prev)
        newbut.selected=true
    end
end
save_last()
if started~="" then
    MANAGER_PRINT("Auto started"..started)
end
tpt.register_mouseevent(mouseclick)
tpt.register_keypress(keypress)
