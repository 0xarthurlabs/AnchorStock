package liquidation

import (
	"container/heap"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

// PriorityItem 优先级队列项 / Priority queue item
type PriorityItem struct {
	User         common.Address
	HealthFactor *big.Int // 健康因子（越小优先级越高）/ Health factor (smaller = higher priority)
	Index        int      // 堆索引 / Heap index
}

// PriorityQueue 优先级队列 / Priority queue
type PriorityQueue []*PriorityItem

// Len 返回队列长度 / Return queue length
func (pq PriorityQueue) Len() int { return len(pq) }

// Less 比较函数（健康因子越小，优先级越高）/ Comparison function (smaller health factor = higher priority)
func (pq PriorityQueue) Less(i, j int) bool {
	return pq[i].HealthFactor.Cmp(pq[j].HealthFactor) < 0
}

// Swap 交换元素 / Swap elements
func (pq PriorityQueue) Swap(i, j int) {
	pq[i], pq[j] = pq[j], pq[i]
	pq[i].Index = i
	pq[j].Index = j
}

// Push 添加元素 / Add element
func (pq *PriorityQueue) Push(x interface{}) {
	n := len(*pq)
	item := x.(*PriorityItem)
	item.Index = n
	*pq = append(*pq, item)
}

// Pop 移除并返回最高优先级元素 / Remove and return highest priority element
func (pq *PriorityQueue) Pop() interface{} {
	old := *pq
	n := len(old)
	item := old[n-1]
	old[n-1] = nil
	item.Index = -1
	*pq = old[0 : n-1]
	return item
}

// NewPriorityQueue 创建优先级队列 / Create priority queue
func NewPriorityQueue() *PriorityQueue {
	pq := make(PriorityQueue, 0)
	heap.Init(&pq)
	return &pq
}

// Add 添加用户到优先级队列 / Add user to priority queue
func (pq *PriorityQueue) Add(user common.Address, healthFactor *big.Int) {
	item := &PriorityItem{
		User:         user,
		HealthFactor: healthFactor,
	}
	heap.Push(pq, item)
}

// PopHighestPriority 弹出最高优先级项 / Pop highest priority item
func (pq *PriorityQueue) PopHighestPriority() (*PriorityItem, bool) {
	if pq.Len() == 0 {
		return nil, false
	}
	item := heap.Pop(pq).(*PriorityItem)
	return item, true
}

// Peek 查看最高优先级项（不移除）/ Peek at highest priority item (without removing)
func (pq *PriorityQueue) Peek() (*PriorityItem, bool) {
	if pq.Len() == 0 {
		return nil, false
	}
	return (*pq)[0], true
}

// Clear 清空队列 / Clear queue
func (pq *PriorityQueue) Clear() {
	*pq = PriorityQueue{}
	heap.Init(pq)
}
