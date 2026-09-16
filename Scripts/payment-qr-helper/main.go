package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/bramvr/goinvoiceqr/internal/invoiceqr"
)

const maxInputBytes = 65536

type request struct {
	Payee     string `json:"payee"`
	IBAN      string `json:"iban"`
	BIC       string `json:"bic"`
	Amount    string `json:"amount"`
	Reference string `json:"reference"`
}

type response struct {
	Payee         string `json:"payee"`
	IBAN          string `json:"iban"`
	BIC           string `json:"bic"`
	Amount        string `json:"amount"`
	Reference     string `json:"reference"`
	ReferenceKind string `json:"referenceKind"`
	Payload       string `json:"payload"`
	PNG           []byte `json:"png"`
}

func run(input io.Reader, output io.Writer) error {
	data, err := io.ReadAll(io.LimitReader(input, maxInputBytes+1))
	if err != nil || len(data) > maxInputBytes {
		return errors.New("invalid input")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var value request
	if err := decoder.Decode(&value); err != nil {
		return errors.New("invalid input")
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return errors.New("invalid input")
	}
	validated, err := invoiceqr.ValidatePaymentDetails(invoiceqr.PaymentDetails{
		Payee: value.Payee, IBAN: value.IBAN, BIC: value.BIC,
		Amount: value.Amount, Reference: value.Reference,
	})
	if err != nil || validated.Reference.Kind != invoiceqr.StructuredReference {
		return errors.New("invalid input")
	}
	epcReference := validated.Reference
	epcReference.Value = "+++/" + strings.TrimPrefix(epcReference.Value, "+++")
	epc, err := invoiceqr.BuildEPCPayloadData(invoiceqr.ConfirmedPaymentDetails{
		Payee: validated.Payee, IBAN: validated.IBAN, BIC: validated.BIC,
		Amount: validated.Amount, Reference: epcReference,
	})
	if err != nil {
		return errors.New("generation failed")
	}
	png, err := invoiceqr.RenderQRCode(epc.Payload, invoiceqr.QRFormatPNG)
	if err != nil {
		return errors.New("generation failed")
	}
	return json.NewEncoder(output).Encode(response{
		Payee: validated.Payee, IBAN: validated.IBAN, BIC: validated.BIC,
		Amount: validated.Amount, Reference: validated.Reference.Value,
		ReferenceKind: string(validated.Reference.Kind), Payload: epc.Payload, PNG: png,
	})
}

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "payment-qr: "+err.Error())
		os.Exit(2)
	}
}
