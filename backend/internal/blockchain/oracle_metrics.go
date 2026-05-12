package blockchain

import (
	"github.com/prometheus/client_golang/prometheus"
)

var (
	oracleInflightTx = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "anchorstock",
		Subsystem: "oracle",
		Name:      "inflight_transactions",
		Help:      "1 while a state-changing oracle transaction is being prepared/sent; 0 otherwise.",
	})

	oraclePendingNonce = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "anchorstock",
		Subsystem: "oracle",
		Name:      "pending_nonce",
		Help:      "Last observed pending nonce for the oracle signer (from eth_getTransactionCount pending).",
	})

	oracleChainHead = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "anchorstock",
		Subsystem: "oracle",
		Name:      "chain_head_block",
		Help:      "Latest block number from the RPC after a successful send (best-effort).",
	})

	oracleRPCError = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Namespace: "anchorstock",
			Subsystem: "oracle",
			Name:      "rpc_errors_total",
			Help:      "RPC or client errors in oracle paths, labeled by phase.",
		},
		[]string{"phase"},
	)
)

func init() {
	prometheus.MustRegister(oracleInflightTx, oraclePendingNonce, oracleChainHead, oracleRPCError)
}

func recordOracleRPCError(phase string) {
	oracleRPCError.WithLabelValues(phase).Inc()
}
