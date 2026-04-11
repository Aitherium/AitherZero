'use client'

import React, { useState, useEffect, useCallback } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { useSparkKV } from '@/lib/spark-kv'
import { toast } from 'sonner'
import {
  Bell, Clock, Calendar, CheckSquare, StickyNote, Timer, 
  ChevronRight, ChevronLeft, X, Plus, Trash2, Check, 
  Edit2, AlertCircle, Info, CheckCircle2, XCircle,
  Sun, Moon, Cloud, CloudRain, Thermometer, Wind,
  Calculator, Bookmark, Music, Pause, Play, SkipForward,
  Volume2, Cpu, HardDrive, Wifi, Battery, RefreshCw,
  Settings, Maximize2, Minimize2, GripVertical
} from 'lucide-react'

import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Checkbox } from '@/components/ui/checkbox'
import { Progress } from '@/components/ui/progress'
import { Separator } from '@/components/ui/separator'

// ============================================================================
// TYPES
// ============================================================================

interface Notification {
  id: string
  type: 'info' | 'success' | 'warning' | 'error'
  title: string
  message: string
  timestamp: Date
  read: boolean
}

interface TodoItem {
  id: string
  text: string
  completed: boolean
  priority: 'low' | 'medium' | 'high'
  createdAt: Date
}

interface Note {
  id: string
  title: string
  content: string
  color: string
  createdAt: Date
  updatedAt: Date
}

interface CalendarEvent {
  id: string
  title: string
  date: Date
  time?: string
  color: string
}

interface PomodoroState {
  isRunning: boolean
  timeLeft: number
  mode: 'work' | 'break'
  sessions: number
}

// ============================================================================
// UTILITY COMPONENTS
// ============================================================================

function ClockWidget() {
  const [time, setTime] = useState(new Date())

  useEffect(() => {
    const timer = setInterval(() => setTime(new Date()), 1000)
    return () => clearInterval(timer)
  }, [])

  const formatTime = (date: Date) => {
    return date.toLocaleTimeString('en-US', { 
      hour: '2-digit', 
      minute: '2-digit',
      second: '2-digit',
      hour12: true 
    })
  }

  const formatDate = (date: Date) => {
    return date.toLocaleDateString('en-US', { 
      weekday: 'short',
      month: 'short', 
      day: 'numeric',
      year: 'numeric'
    })
  }

  return (
    <div className="text-center py-4">
      <div className="text-3xl font-mono font-bold text-primary tracking-wider">
        {formatTime(time)}
      </div>
      <div className="text-sm text-muted-foreground mt-1">
        {formatDate(time)}
      </div>
    </div>
  )
}

function NotificationsWidget({ 
  notifications, 
  onDismiss, 
  onClear, 
  onMarkRead 
}: { 
  notifications: Notification[]
  onDismiss: (id: string) => void
  onClear: () => void
  onMarkRead: (id: string) => void
}) {
  const unreadCount = notifications.filter(n => !n.read).length

  const getIcon = (type: Notification['type']) => {
    switch (type) {
      case 'success': return <CheckCircle2 className="w-4 h-4 text-green-500" />
      case 'warning': return <AlertCircle className="w-4 h-4 text-yellow-500" />
      case 'error': return <XCircle className="w-4 h-4 text-red-500" />
      default: return <Info className="w-4 h-4 text-blue-500" />
    }
  }

  const getBgColor = (type: Notification['type']) => {
    switch (type) {
      case 'success': return 'bg-green-500/10 border-green-500/20'
      case 'warning': return 'bg-yellow-500/10 border-yellow-500/20'
      case 'error': return 'bg-red-500/10 border-red-500/20'
      default: return 'bg-blue-500/10 border-blue-500/20'
    }
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Bell className="w-4 h-4" />
          <span className="font-medium text-sm">Notifications</span>
          {unreadCount > 0 && (
            <Badge variant="destructive" className="h-5 px-1.5 text-[10px]">
              {unreadCount}
            </Badge>
          )}
        </div>
        {notifications.length > 0 && (
          <Button variant="ghost" size="sm" onClick={onClear} className="h-6 text-xs">
            Clear All
          </Button>
        )}
      </div>

      <ScrollArea className="h-[180px]">
        {notifications.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full text-muted-foreground text-sm py-8">
            <Bell className="w-8 h-8 mb-2 opacity-30" />
            <p>No notifications</p>
          </div>
        ) : (
          <div className="space-y-2">
            {notifications.map(notif => (
              <motion.div
                key={notif.id}
                initial={{ opacity: 0, x: 20 }}
                animate={{ opacity: 1, x: 0 }}
                exit={{ opacity: 0, x: -20 }}
                className={`p-3 rounded-lg border ${getBgColor(notif.type)} ${!notif.read ? 'ring-1 ring-primary/30' : 'opacity-70'}`}
                onClick={() => onMarkRead(notif.id)}
              >
                <div className="flex items-start gap-2">
                  {getIcon(notif.type)}
                  <div className="flex-1 min-w-0">
                    <p className="text-xs font-medium truncate">{notif.title}</p>
                    <p className="text-[10px] text-muted-foreground line-clamp-2">{notif.message}</p>
                  </div>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="h-5 w-5 shrink-0"
                    onClick={(e) => { e.stopPropagation(); onDismiss(notif.id) }}
                  >
                    <X className="w-3 h-3" />
                  </Button>
                </div>
              </motion.div>
            ))}
          </div>
        )}
      </ScrollArea>
    </div>
  )
}

function CalendarWidget({ events, onAddEvent }: { events: CalendarEvent[], onAddEvent: (event: CalendarEvent) => void }) {
  const [currentDate, setCurrentDate] = useState(new Date())
  const [selectedDate, setSelectedDate] = useState<Date | null>(null)
  const [newEventTitle, setNewEventTitle] = useState('')

  const daysInMonth = new Date(currentDate.getFullYear(), currentDate.getMonth() + 1, 0).getDate()
  const firstDayOfMonth = new Date(currentDate.getFullYear(), currentDate.getMonth(), 1).getDay()
  
  const monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 
                      'July', 'August', 'September', 'October', 'November', 'December']
  const dayNames = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa']

  const prevMonth = () => {
    setCurrentDate(new Date(currentDate.getFullYear(), currentDate.getMonth() - 1, 1))
  }

  const nextMonth = () => {
    setCurrentDate(new Date(currentDate.getFullYear(), currentDate.getMonth() + 1, 1))
  }

  const isToday = (day: number) => {
    const today = new Date()
    return day === today.getDate() && 
           currentDate.getMonth() === today.getMonth() && 
           currentDate.getFullYear() === today.getFullYear()
  }

  const hasEvent = (day: number) => {
    return events.some(e => {
      const eventDate = new Date(e.date)
      return eventDate.getDate() === day &&
             eventDate.getMonth() === currentDate.getMonth() &&
             eventDate.getFullYear() === currentDate.getFullYear()
    })
  }

  const handleAddEvent = () => {
    if (selectedDate && newEventTitle.trim()) {
      onAddEvent({
        id: `event-${Date.now()}`,
        title: newEventTitle,
        date: selectedDate,
        color: 'bg-primary'
      })
      setNewEventTitle('')
      setSelectedDate(null)
      toast.success('Event added!')
    }
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Calendar className="w-4 h-4" />
          <span className="font-medium text-sm">Calendar</span>
        </div>
      </div>

      <div className="bg-muted/30 rounded-lg p-3">
        {/* Month Navigation */}
        <div className="flex items-center justify-between mb-3">
          <Button variant="ghost" size="icon" className="h-6 w-6" onClick={prevMonth}>
            <ChevronLeft className="w-4 h-4" />
          </Button>
          <span className="text-sm font-medium">
            {monthNames[currentDate.getMonth()]} {currentDate.getFullYear()}
          </span>
          <Button variant="ghost" size="icon" className="h-6 w-6" onClick={nextMonth}>
            <ChevronRight className="w-4 h-4" />
          </Button>
        </div>

        {/* Day Headers */}
        <div className="grid grid-cols-7 gap-1 mb-2">
          {dayNames.map(day => (
            <div key={day} className="text-center text-[10px] text-muted-foreground font-medium">
              {day}
            </div>
          ))}
        </div>

        {/* Calendar Grid */}
        <div className="grid grid-cols-7 gap-1">
          {Array.from({ length: firstDayOfMonth }).map((_, i) => (
            <div key={`empty-${i}`} className="h-7" />
          ))}
          {Array.from({ length: daysInMonth }).map((_, i) => {
            const day = i + 1
            const dateForDay = new Date(currentDate.getFullYear(), currentDate.getMonth(), day)
            const isSelected = selectedDate?.getTime() === dateForDay.getTime()
            
            return (
              <button
                key={day}
                onClick={() => setSelectedDate(dateForDay)}
                className={`
                  h-7 text-xs rounded-md relative transition-colors
                  ${isToday(day) ? 'bg-primary text-primary-foreground font-bold' : ''}
                  ${isSelected && !isToday(day) ? 'bg-accent' : ''}
                  ${!isToday(day) && !isSelected ? 'hover:bg-muted' : ''}
                `}
              >
                {day}
                {hasEvent(day) && (
                  <span className="absolute bottom-0.5 left-1/2 -translate-x-1/2 w-1 h-1 rounded-full bg-primary" />
                )}
              </button>
            )
          })}
        </div>

        {/* Add Event */}
        {selectedDate && (
          <motion.div
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: 'auto' }}
            className="mt-3 pt-3 border-t border-border/50"
          >
            <div className="flex gap-2">
              <Input
                value={newEventTitle}
                onChange={e => setNewEventTitle(e.target.value)}
                placeholder={`Event for ${selectedDate.toLocaleDateString()}`}
                className="h-8 text-xs"
                onKeyDown={e => e.key === 'Enter' && handleAddEvent()}
              />
              <Button size="sm" className="h-8" onClick={handleAddEvent}>
                <Plus className="w-3 h-3" />
              </Button>
            </div>
          </motion.div>
        )}
      </div>

      {/* Upcoming Events */}
      {events.length > 0 && (
        <div className="space-y-1.5">
          <p className="text-xs text-muted-foreground">Upcoming</p>
          {events.slice(0, 3).map(event => (
            <div key={event.id} className="flex items-center gap-2 text-xs p-2 rounded bg-muted/30">
              <div className={`w-2 h-2 rounded-full ${event.color}`} />
              <span className="truncate flex-1">{event.title}</span>
              <span className="text-muted-foreground text-[10px]">
                {new Date(event.date).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

function TodoWidget({ 
  todos, 
  onAdd, 
  onToggle, 
  onDelete 
}: { 
  todos: TodoItem[]
  onAdd: (text: string, priority: TodoItem['priority']) => void
  onToggle: (id: string) => void
  onDelete: (id: string) => void
}) {
  const [newTodo, setNewTodo] = useState('')
  const [priority, setPriority] = useState<TodoItem['priority']>('medium')

  const handleAdd = () => {
    if (newTodo.trim()) {
      onAdd(newTodo.trim(), priority)
      setNewTodo('')
    }
  }

  const getPriorityColor = (p: TodoItem['priority']) => {
    switch (p) {
      case 'high': return 'border-red-500'
      case 'medium': return 'border-yellow-500'
      case 'low': return 'border-green-500'
    }
  }

  const completedCount = todos.filter(t => t.completed).length
  const progress = todos.length > 0 ? (completedCount / todos.length) * 100 : 0

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <CheckSquare className="w-4 h-4" />
          <span className="font-medium text-sm">To-Do List</span>
        </div>
        <Badge variant="outline" className="text-[10px]">
          {completedCount}/{todos.length}
        </Badge>
      </div>

      <Progress value={progress} className="h-1.5" />

      <div className="flex gap-2">
        <Input
          value={newTodo}
          onChange={e => setNewTodo(e.target.value)}
          placeholder="Add a task..."
          className="h-8 text-xs"
          onKeyDown={e => e.key === 'Enter' && handleAdd()}
        />
        <select 
          value={priority}
          onChange={e => setPriority(e.target.value as TodoItem['priority'])}
          className="h-8 text-xs bg-muted border-none rounded px-2"
        >
          <option value="low">Low</option>
          <option value="medium">Med</option>
          <option value="high">High</option>
        </select>
        <Button size="sm" className="h-8 px-2" onClick={handleAdd}>
          <Plus className="w-3 h-3" />
        </Button>
      </div>

      <ScrollArea className="h-[160px]">
        <div className="space-y-2">
          {todos.length === 0 ? (
            <div className="flex flex-col items-center justify-center h-full text-muted-foreground text-sm py-8">
              <CheckSquare className="w-8 h-8 mb-2 opacity-30" />
              <p>No tasks yet</p>
            </div>
          ) : (
            todos.map(todo => (
              <motion.div
                key={todo.id}
                initial={{ opacity: 0, y: 10 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, x: -20 }}
                className={`flex items-center gap-2 p-2 rounded-lg bg-muted/30 border-l-2 ${getPriorityColor(todo.priority)} ${todo.completed ? 'opacity-50' : ''}`}
              >
                <Checkbox 
                  checked={todo.completed}
                  onCheckedChange={() => onToggle(todo.id)}
                />
                <span className={`flex-1 text-xs ${todo.completed ? 'line-through text-muted-foreground' : ''}`}>
                  {todo.text}
                </span>
                <Button variant="ghost" size="icon" className="h-5 w-5" onClick={() => onDelete(todo.id)}>
                  <Trash2 className="w-3 h-3" />
                </Button>
              </motion.div>
            ))
          )}
        </div>
      </ScrollArea>
    </div>
  )
}

function NotesWidget({
  notes,
  onAdd,
  onUpdate,
  onDelete
}: {
  notes: Note[]
  onAdd: () => void
  onUpdate: (id: string, content: string) => void
  onDelete: (id: string) => void
}) {
  const [selectedNote, setSelectedNote] = useState<Note | null>(null)
  const [editContent, setEditContent] = useState('')

  const colors = [
    'bg-yellow-500/20',
    'bg-blue-500/20',
    'bg-green-500/20',
    'bg-purple-500/20',
    'bg-pink-500/20',
  ]

  const handleSave = () => {
    if (selectedNote) {
      onUpdate(selectedNote.id, editContent)
      setSelectedNote(null)
    }
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <StickyNote className="w-4 h-4" />
          <span className="font-medium text-sm">Quick Notes</span>
        </div>
        <Button variant="ghost" size="sm" className="h-6 text-xs" onClick={onAdd}>
          <Plus className="w-3 h-3 mr-1" /> New
        </Button>
      </div>

      {selectedNote ? (
        <motion.div
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          className="space-y-2"
        >
          <Textarea
            value={editContent}
            onChange={e => setEditContent(e.target.value)}
            className="h-32 text-xs resize-none"
            placeholder="Write your note..."
          />
          <div className="flex gap-2">
            <Button size="sm" className="flex-1 h-7" onClick={handleSave}>
              <Check className="w-3 h-3 mr-1" /> Save
            </Button>
            <Button variant="outline" size="sm" className="h-7" onClick={() => setSelectedNote(null)}>
              Cancel
            </Button>
          </div>
        </motion.div>
      ) : (
        <ScrollArea className="h-[120px]">
          <div className="grid grid-cols-2 gap-2">
            {notes.length === 0 ? (
              <div className="col-span-2 flex flex-col items-center justify-center text-muted-foreground text-sm py-6">
                <StickyNote className="w-8 h-8 mb-2 opacity-30" />
                <p>No notes yet</p>
              </div>
            ) : (
              notes.map((note, i) => (
                <motion.div
                  key={note.id}
                  initial={{ opacity: 0, scale: 0.9 }}
                  animate={{ opacity: 1, scale: 1 }}
                  className={`p-2 rounded-lg ${note.color || colors[i % colors.length]} cursor-pointer group relative`}
                  onClick={() => { setSelectedNote(note); setEditContent(note.content) }}
                >
                  <p className="text-[10px] font-medium truncate">{note.title}</p>
                  <p className="text-[9px] text-muted-foreground line-clamp-2 mt-1">
                    {note.content || 'Empty note...'}
                  </p>
                  <Button
                    variant="ghost"
                    size="icon"
                    className="absolute top-1 right-1 h-4 w-4 opacity-0 group-hover:opacity-100 transition-opacity"
                    onClick={(e) => { e.stopPropagation(); onDelete(note.id) }}
                  >
                    <X className="w-2 h-2" />
                  </Button>
                </motion.div>
              ))
            )}
          </div>
        </ScrollArea>
      )}
    </div>
  )
}

function PomodoroWidget() {
  const [state, setState] = useSparkKV<PomodoroState>('pomodoro-state', {
    isRunning: false,
    timeLeft: 25 * 60, // 25 minutes
    mode: 'work',
    sessions: 0
  })

  useEffect(() => {
    let interval: NodeJS.Timeout | null = null
    
    if (state.isRunning && state.timeLeft > 0) {
      interval = setInterval(() => {
        setState(prev => ({ ...prev, timeLeft: prev.timeLeft - 1 }))
      }, 1000)
    } else if (state.timeLeft === 0) {
      // Switch modes
      if (state.mode === 'work') {
        setState(prev => ({
          ...prev,
          mode: 'break',
          timeLeft: 5 * 60, // 5 minute break
          sessions: prev.sessions + 1,
          isRunning: false
        }))
        toast.success('Work session complete! Take a break.')
      } else {
        setState(prev => ({
          ...prev,
          mode: 'work',
          timeLeft: 25 * 60,
          isRunning: false
        }))
        toast.info('Break over! Ready for next session?')
      }
    }

    return () => { if (interval) clearInterval(interval) }
  }, [state.isRunning, state.timeLeft])

  const toggleTimer = () => {
    setState(prev => ({ ...prev, isRunning: !prev.isRunning }))
  }

  const resetTimer = () => {
    setState({
      isRunning: false,
      timeLeft: state.mode === 'work' ? 25 * 60 : 5 * 60,
      mode: state.mode,
      sessions: state.sessions
    })
  }

  const formatTime = (seconds: number) => {
    const mins = Math.floor(seconds / 60)
    const secs = seconds % 60
    return `${mins.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`
  }

  const progress = state.mode === 'work' 
    ? ((25 * 60 - state.timeLeft) / (25 * 60)) * 100
    : ((5 * 60 - state.timeLeft) / (5 * 60)) * 100

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Timer className="w-4 h-4" />
          <span className="font-medium text-sm">Pomodoro</span>
        </div>
        <Badge variant={state.mode === 'work' ? 'default' : 'secondary'} className="text-[10px]">
          {state.mode === 'work' ? 'Focus' : 'Break'} • {state.sessions} done
        </Badge>
      </div>

      <div className="relative">
        <div className="flex flex-col items-center justify-center py-4 bg-muted/30 rounded-lg">
          <div className={`text-4xl font-mono font-bold ${state.mode === 'work' ? 'text-primary' : 'text-green-500'}`}>
            {formatTime(state.timeLeft)}
          </div>
          <Progress value={progress} className={`h-1 w-3/4 mt-3 ${state.mode === 'break' ? '[&>div]:bg-green-500' : ''}`} />
        </div>
        
        <div className="flex items-center justify-center gap-2 mt-3">
          <Button 
            variant={state.isRunning ? 'outline' : 'default'} 
            size="sm" 
            onClick={toggleTimer}
            className="gap-1"
          >
            {state.isRunning ? <Pause className="w-3 h-3" /> : <Play className="w-3 h-3" />}
            {state.isRunning ? 'Pause' : 'Start'}
          </Button>
          <Button variant="ghost" size="sm" onClick={resetTimer}>
            <RefreshCw className="w-3 h-3" />
          </Button>
        </div>
      </div>
    </div>
  )
}

function SystemMonitorWidget() {
  const [stats, setStats] = useState({
    cpu: 45,
    memory: 62,
    disk: 73,
    network: 'Connected'
  })

  // Simulate real-time updates
  useEffect(() => {
    const interval = setInterval(() => {
      setStats(prev => ({
        ...prev,
        cpu: Math.min(100, Math.max(10, prev.cpu + (Math.random() - 0.5) * 10)),
        memory: Math.min(100, Math.max(20, prev.memory + (Math.random() - 0.5) * 5)),
      }))
    }, 2000)
    return () => clearInterval(interval)
  }, [])

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2">
        <Cpu className="w-4 h-4" />
        <span className="font-medium text-sm">System Monitor</span>
      </div>

      <div className="space-y-2">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Cpu className="w-3 h-3 text-blue-500" />
            <span className="text-xs">CPU</span>
          </div>
          <span className="text-xs font-mono">{Math.round(stats.cpu)}%</span>
        </div>
        <Progress value={stats.cpu} className="h-1.5 [&>div]:bg-blue-500" />

        <div className="flex items-center justify-between mt-2">
          <div className="flex items-center gap-2">
            <HardDrive className="w-3 h-3 text-purple-500" />
            <span className="text-xs">Memory</span>
          </div>
          <span className="text-xs font-mono">{Math.round(stats.memory)}%</span>
        </div>
        <Progress value={stats.memory} className="h-1.5 [&>div]:bg-purple-500" />

        <div className="flex items-center justify-between mt-2">
          <div className="flex items-center gap-2">
            <HardDrive className="w-3 h-3 text-green-500" />
            <span className="text-xs">Disk</span>
          </div>
          <span className="text-xs font-mono">{stats.disk}%</span>
        </div>
        <Progress value={stats.disk} className="h-1.5 [&>div]:bg-green-500" />

        <div className="flex items-center justify-between mt-3 pt-2 border-t">
          <div className="flex items-center gap-2">
            <Wifi className="w-3 h-3 text-green-500" />
            <span className="text-xs">Network</span>
          </div>
          <Badge variant="outline" className="text-[10px] text-green-500">
            {stats.network}
          </Badge>
        </div>
      </div>
    </div>
  )
}

function QuickLinksWidget() {
  const links = [
    { icon: Bookmark, label: 'Documentation', url: '#' },
    { icon: Settings, label: 'Settings', url: '#' },
    { icon: Calculator, label: 'Calculator', url: '#' },
  ]

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2">
        <Bookmark className="w-4 h-4" />
        <span className="font-medium text-sm">Quick Links</span>
      </div>

      <div className="grid grid-cols-3 gap-2">
        {links.map((link, i) => (
          <Button
            key={i}
            variant="ghost"
            className="h-auto flex-col py-3 gap-1"
            onClick={() => toast.info(`Opening ${link.label}...`)}
          >
            <link.icon className="w-4 h-4" />
            <span className="text-[10px]">{link.label}</span>
          </Button>
        ))}
      </div>
    </div>
  )
}

// ============================================================================
// MAIN SIDEBAR COMPONENT
// ============================================================================

export default function UtilitySidebar({ 
  isOpen, 
  onToggle 
}: { 
  isOpen: boolean
  onToggle: () => void 
}) {
  // Persisted state
  const [notifications, setNotifications] = useSparkKV<Notification[]>('sidebar-notifications', [
    {
      id: '1',
      type: 'success',
      title: 'Build Complete',
      message: 'Production deployment finished successfully',
      timestamp: new Date(),
      read: false
    },
    {
      id: '2',
      type: 'warning',
      title: 'High Memory Usage',
      message: 'System memory usage exceeded 80%',
      timestamp: new Date(Date.now() - 300000),
      read: false
    },
    {
      id: '3',
      type: 'info',
      title: 'Agent Update Available',
      message: 'NarrativeAgent v2.1.0 is ready to install',
      timestamp: new Date(Date.now() - 600000),
      read: true
    }
  ])

  const [todos, setTodos] = useSparkKV<TodoItem[]>('sidebar-todos', [
    { id: '1', text: 'Review pull requests', completed: false, priority: 'high', createdAt: new Date() },
    { id: '2', text: 'Update documentation', completed: true, priority: 'medium', createdAt: new Date() },
    { id: '3', text: 'Test new agent workflow', completed: false, priority: 'low', createdAt: new Date() },
  ])

  const [notes, setNotes] = useSparkKV<Note[]>('sidebar-notes', [
    { id: '1', title: 'API Keys', content: 'Remember to rotate keys monthly', color: 'bg-yellow-500/20', createdAt: new Date(), updatedAt: new Date() },
    { id: '2', title: 'Deploy Notes', content: 'Check staging before prod', color: 'bg-blue-500/20', createdAt: new Date(), updatedAt: new Date() },
  ])

  const [events, setEvents] = useSparkKV<CalendarEvent[]>('sidebar-events', [
    { id: '1', title: 'Sprint Review', date: new Date(), color: 'bg-primary' },
    { id: '2', title: 'Team Standup', date: new Date(Date.now() + 86400000), color: 'bg-green-500' },
  ])

  // Handlers
  const handleDismissNotification = (id: string) => {
    setNotifications(prev => prev.filter(n => n.id !== id))
  }

  const handleClearNotifications = () => {
    setNotifications([])
  }

  const handleMarkRead = (id: string) => {
    setNotifications(prev => prev.map(n => n.id === id ? { ...n, read: true } : n))
  }

  const handleAddTodo = (text: string, priority: TodoItem['priority']) => {
    setTodos(prev => [...prev, {
      id: `todo-${Date.now()}`,
      text,
      completed: false,
      priority,
      createdAt: new Date()
    }])
  }

  const handleToggleTodo = (id: string) => {
    setTodos(prev => prev.map(t => t.id === id ? { ...t, completed: !t.completed } : t))
  }

  const handleDeleteTodo = (id: string) => {
    setTodos(prev => prev.filter(t => t.id !== id))
  }

  const handleAddNote = () => {
    const colors = ['bg-yellow-500/20', 'bg-blue-500/20', 'bg-green-500/20', 'bg-purple-500/20', 'bg-pink-500/20']
    setNotes(prev => [...prev, {
      id: `note-${Date.now()}`,
      title: `Note ${prev.length + 1}`,
      content: '',
      color: colors[Math.floor(Math.random() * colors.length)],
      createdAt: new Date(),
      updatedAt: new Date()
    }])
  }

  const handleUpdateNote = (id: string, content: string) => {
    setNotes(prev => prev.map(n => n.id === id ? { ...n, content, updatedAt: new Date() } : n))
  }

  const handleDeleteNote = (id: string) => {
    setNotes(prev => prev.filter(n => n.id !== id))
  }

  const handleAddEvent = (event: CalendarEvent) => {
    setEvents(prev => [...prev, event])
  }

  return (
    <>
      {/* Toggle Button (always visible) */}
      <Button
        variant="outline"
        size="icon"
        onClick={onToggle}
        className={`fixed top-20 z-40 transition-all duration-300 ${isOpen ? 'right-[340px]' : 'right-4'} shadow-lg bg-background`}
      >
        {isOpen ? <ChevronRight className="w-4 h-4" /> : <ChevronLeft className="w-4 h-4" />}
      </Button>

      {/* Sidebar Panel */}
      <AnimatePresence>
        {isOpen && (
          <motion.aside
            initial={{ x: 340, opacity: 0 }}
            animate={{ x: 0, opacity: 1 }}
            exit={{ x: 340, opacity: 0 }}
            transition={{ type: 'spring', damping: 25, stiffness: 300 }}
            className="fixed top-0 right-0 h-screen w-[320px] bg-background border-l border-border z-30 shadow-2xl flex flex-col"
          >
            {/* Header */}
            <div className="flex items-center justify-between px-4 py-3 border-b bg-card/50">
              <div className="flex items-center gap-2">
                <div className="p-1.5 rounded-md bg-primary/10">
                  <Settings className="w-4 h-4 text-primary" />
                </div>
                <span className="font-semibold text-sm">Utilities</span>
              </div>
              <Button variant="ghost" size="icon" className="h-7 w-7" onClick={onToggle}>
                <X className="w-4 h-4" />
              </Button>
            </div>

            {/* Content */}
            <ScrollArea className="flex-1">
              <div className="p-4 space-y-6">
                {/* Clock */}
                <ClockWidget />
                
                <Separator />

                {/* Notifications */}
                <NotificationsWidget 
                  notifications={notifications}
                  onDismiss={handleDismissNotification}
                  onClear={handleClearNotifications}
                  onMarkRead={handleMarkRead}
                />

                <Separator />

                {/* Pomodoro Timer */}
                <PomodoroWidget />

                <Separator />

                {/* Calendar */}
                <CalendarWidget 
                  events={events}
                  onAddEvent={handleAddEvent}
                />

                <Separator />

                {/* To-Do List */}
                <TodoWidget 
                  todos={todos}
                  onAdd={handleAddTodo}
                  onToggle={handleToggleTodo}
                  onDelete={handleDeleteTodo}
                />

                <Separator />

                {/* Quick Notes */}
                <NotesWidget 
                  notes={notes}
                  onAdd={handleAddNote}
                  onUpdate={handleUpdateNote}
                  onDelete={handleDeleteNote}
                />

                <Separator />

                {/* System Monitor */}
                <SystemMonitorWidget />

                <Separator />

                {/* Quick Links */}
                <QuickLinksWidget />

                {/* Bottom padding for scroll */}
                <div className="h-8" />
              </div>
            </ScrollArea>
          </motion.aside>
        )}
      </AnimatePresence>
    </>
  )
}
